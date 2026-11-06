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
                if let renderer = model.terminalRenderers[pane.id] {
                    Text(renderer == "Metal" ? "Metal" : "Metal unavailable")
                        .foregroundStyle(renderer == "Metal" ? Palette.muted : .orange)
                        .help(renderer)
                }
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

final class AcceleratedTerminalView: TerminalView {
    var rendererChanged: ((String) -> Void)?
    private var attemptedMetal = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !attemptedMetal else { return }
        attemptedMetal = true
        do {
            try setUseMetal(true)
            rendererChanged?("Metal")
        } catch {
            rendererChanged?("Metal unavailable: \(error.localizedDescription)")
        }
    }
}

struct ManagedTerminalHost: NSViewRepresentable {
    @ObservedObject var model: AppModel
    @ObservedObject private var appearance = TerminalAppearance.shared
    let pane: TerminalPane
    func makeCoordinator() -> Coordinator { Coordinator(model: model, pane: pane) }
    func makeNSView(context: Context) -> TerminalView {
        let view = AcceleratedTerminalView(frame: .zero, font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular))
        view.rendererChanged = { [weak model] status in
            Task { @MainActor in model?.terminalRenderers[pane.id] = status }
        }
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
        if running && !context.coordinator.wasRunning { context.coordinator.resize(view); context.coordinator.resumeIfNeeded() }
        context.coordinator.wasRunning = running
        if model.focusedPaneID == pane.id {
            DispatchQueue.main.async { [weak view, weak model] in
                guard let view, let model, model.focusedPaneID == pane.id else { return }
                if model.terminal !== view { model.terminal = view; view.window?.makeFirstResponder(view) }
            }
        }
    }
    static func dismantleNSView(_ view: TerminalView, coordinator: Coordinator) { coordinator.end() }

    // Coordinator state is accessed on the main thread; callbacks hand off before touching it.
    final class Coordinator: NSObject, TerminalViewDelegate, @unchecked Sendable {
        let model: AppModel
        let pane: TerminalPane
        private let client = RuntimeClient()
        private let queue = DispatchQueue(label: "RunDock.pane", qos: .userInitiated)
        private var stream: OutputStreamHandle?
        private var streamEnded = false
        private var streamGeneration = UUID()
        private var reconnectScheduled = false
        private var retryDelay = 0.25
        private var reportedStreamError = false
        private var offset: UInt64 = 0
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
            startStream()
        }
        func end() {
            active = false; stream?.cancel(); stream = nil; view = nil
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }; mouseMonitor = nil
        }
        func resumeIfNeeded() {
            if streamEnded && !reconnectScheduled { startStream() }
        }
        private func startStream() {
            guard active else { return }
            stream?.cancel()
            streamEnded = false
            let generation = UUID(); streamGeneration = generation
            stream = client.streamOutput(id: pane.serviceID, offset: offset) { [weak self] event in
                // Synchronous handoff bounds queued output while the main thread parses/renders.
                DispatchQueue.main.sync {
                    guard let self, self.active, self.streamGeneration == generation, let view = self.view else { return }
                    switch event {
                    case .success(let response):
                        if let data = response.data, !data.isEmpty {
                            if let end = response.offset, end >= UInt64(data.count), end - UInt64(data.count) > self.offset {
                                view.feed(text: "\r\n[Older output is no longer retained.]\r\n")
                            }
                            view.feed(byteArray: ArraySlice(data))
                            self.retryDelay = 0.25; self.reportedStreamError = false
                        }
                        self.offset = response.offset ?? self.offset
                        if response.data?.isEmpty != false {
                            self.streamEnded = true; self.scheduleReconnect()
                        }
                    case .failure(let error):
                        self.streamEnded = true
                        if !self.reportedStreamError {
                            self.model.error = "Terminal stream: \(error.localizedDescription)"
                            self.reportedStreamError = true
                        }
                        self.scheduleReconnect()
                    }
                }
            }
        }
        private func scheduleReconnect() {
            guard active, !reconnectScheduled else { return }
            reconnectScheduled = true
            let generation = streamGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak self] in
                guard let self, self.active, self.streamGeneration == generation else { return }
                self.reconnectScheduled = false
                guard self.streamEnded, self.model.services.first(where: { $0.id == self.pane.serviceID })?.status == "running" else { return }
                self.retryDelay = min(self.retryDelay * 2, 2)
                self.startStream()
            }
        }
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let request = Request("input", id: pane.serviceID, data: Data(data))
            queue.async { [weak self, client] in
                do { _ = try client.send(request) }
                catch { DispatchQueue.main.async { self?.model.error = error.localizedDescription } }
            }
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
