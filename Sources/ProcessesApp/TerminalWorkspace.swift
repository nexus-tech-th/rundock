import SwiftUI
import AppKit
import SwiftTerm
import ProcessesProtocol

struct TerminalPane: Codable, Identifiable, Equatable {
    var id = UUID()
    var serviceID: String
}
struct TerminalTab: Codable, Identifiable, Equatable {
    var id = UUID()
    var panes: [TerminalPane]
    var horizontal = true
}

struct TerminalWorkspaceView: View {
    @EnvironmentObject var model: AppModel
    let tab: TerminalTab
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(model.tabs) { item in
                            HStack(spacing: 8) {
                                Button { model.activateTab(item) } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: item.panes.count > 1 ? "rectangle.split.2x1" : "terminal")
                                        Text(model.services.first { $0.id == item.panes.first?.serviceID }?.name ?? "Terminal").lineLimit(1)
                                    }.frame(minWidth: 70, maxWidth: 150, alignment: .leading)
                                }.buttonStyle(.plain)
                                Button { model.closeTab(item.id) } label: { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.plain).help("Close tab; processes keep running")
                            }.font(.system(size: 11)).padding(.horizontal, 12).frame(height: 34)
                                .background(item.id == model.activeTabID ? Color.white.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        }
                    }.padding(.horizontal, 7)
                }
                Button { model.newTerminal() } label: { Image(systemName: "plus") }.buttonStyle(.plain).padding(10).help("New Terminal Tab (⌘T)")
                Menu {
                    Button("Split Vertically") { model.newTerminal(split: true) }
                    Button("Split Horizontally") { model.newTerminal(split: true, horizontal: false) }
                } label: { Image(systemName: "rectangle.split.2x1") }.menuStyle(.borderlessButton).fixedSize().padding(.trailing, 12).disabled(tab.panes.count >= 4).help("Split Terminal")
            }.frame(height: 42).background(Palette.sidebar)
            Rectangle().fill(Palette.line).frame(height: 1)
            if tab.horizontal {
                HSplitView { ForEach(tab.panes) { pane in paneView(pane) } }
            } else {
                VSplitView { ForEach(tab.panes) { pane in paneView(pane) } }
            }
        }
    }
    private func paneView(_ pane: TerminalPane) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Circle().fill(Palette.status(model.services.first { $0.id == pane.serviceID }?.status ?? "stopped")).frame(width: 5, height: 5)
                Text(model.services.first { $0.id == pane.serviceID }?.name ?? "Terminal").lineLimit(1)
                Spacer(minLength: 4)
                Text(model.services.first { $0.id == pane.serviceID }?.status.capitalized ?? "").foregroundStyle(Palette.muted)
                if tab.panes.count > 1 {
                    Button { model.closePane(pane, tabID: tab.id) } label: { Image(systemName: "xmark").font(.system(size: 9)) }.buttonStyle(.plain).help("Close pane; process keeps running")
                }
            }.font(.system(size: 10)).padding(.horizontal, 12).frame(height: 29)
                .background(model.focusedPaneID == pane.id ? Palette.mint.opacity(0.08) : Color.clear)
                .contentShape(Rectangle()).onTapGesture { model.focusPane(pane) }
            ManagedTerminalHost(model: model, pane: pane).id("\(pane.id)-\(model.terminalGeneration)")
        }.frame(minWidth: 150, minHeight: 100).overlay(alignment: .top) {
            Rectangle().fill(model.focusedPaneID == pane.id ? Palette.mint.opacity(0.7) : Palette.line).frame(height: 1)
        }
    }
}

struct ManagedTerminalHost: NSViewRepresentable {
    @ObservedObject var model: AppModel
    @ObservedObject private var appearance = TerminalAppearance.shared
    let pane: TerminalPane
    func makeCoordinator() -> Coordinator { Coordinator(model: model, pane: pane) }
    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero, font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        view.terminalDelegate = context.coordinator
        appearance.apply(to: view)
        context.coordinator.appearanceRevision = appearance.revision
        context.coordinator.begin(view)
        return view
    }
    func updateNSView(_ view: TerminalView, context: Context) {
        if context.coordinator.appearanceRevision != appearance.revision {
            appearance.apply(to: view); context.coordinator.appearanceRevision = appearance.revision
        }
        let running = model.services.first { $0.id == pane.serviceID }?.status == "running"
        if running && !context.coordinator.wasRunning { context.coordinator.resize(view) }
        context.coordinator.wasRunning = running
        if model.focusedPaneID == pane.id {
            DispatchQueue.main.async { [weak view, weak model] in
                guard let view, let model, model.focusedPaneID == pane.id else { return }
                if model.terminal !== view { model.terminal = view; view.window?.makeFirstResponder(view) }
            }
        }
    }
    static func dismantleNSView(_ view: TerminalView, coordinator: Coordinator) { coordinator.end() }

    final class Coordinator: NSObject, TerminalViewDelegate {
        let model: AppModel
        let pane: TerminalPane
        private let client = RuntimeClient()
        private let queue = DispatchQueue(label: "RunDock.pane", qos: .userInitiated)
        private var timer: Timer?
        private var offset: UInt64 = 0
        private var reading = false
        private var active = true
        private var mouseMonitor: Any?
        weak var view: TerminalView?
        var appearanceRevision: UUID?
        var wasRunning = false
        init(model: AppModel, pane: TerminalPane) { self.model = model; self.pane = pane }
        func begin(_ view: TerminalView) {
            self.view = view
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self, weak view] event in
                if let self, let view, event.window === view.window, view.bounds.contains(view.convert(event.locationInWindow, from: nil)) {
                    Task { @MainActor in self.model.focusPane(self.pane, terminal: view) }
                }
                return event
            }
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.read() }
            read()
        }
        func end() {
            active = false; timer?.invalidate(); timer = nil; view = nil
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }; mouseMonitor = nil
        }
        private func read() {
            guard active, !reading else { return }; reading = true
            let position = offset, id = pane.serviceID
            queue.async { [weak self, client] in
                let result = try? client.send(Request("read", id: id, offset: position))
                DispatchQueue.main.async {
                    guard let self else { return }; self.reading = false
                    guard self.active, let view = self.view, let result, result.ok else { return }
                    if let data = result.data, !data.isEmpty { view.feed(byteArray: ArraySlice(data)) }
                    self.offset = result.offset ?? position
                }
            }
        }
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let id = pane.serviceID, bytes = Data(data)
            Task { @MainActor in model.send(Request("input", id: id, data: bytes)) }
        }
        func resize(_ source: TerminalView) { let dims = source.getTerminal().getDims(); sizeChanged(source: source, newCols: dims.cols, newRows: dims.rows) }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            let id = pane.serviceID
            Task { @MainActor in
                guard model.services.first(where: { $0.id == id })?.status == "running", newCols > 0, newRows > 0 else { return }
                model.send(Request("resize", id: id, columns: UInt16(clamping: newCols), rows: UInt16(clamping: newRows)))
            }
        }
        func clipboardCopy(source: TerminalView, content: Data) {}
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func bell(source: TerminalView) { NSSound.beep() }
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
