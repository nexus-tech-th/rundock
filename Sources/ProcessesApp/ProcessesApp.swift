import SwiftUI
import AppKit
import ProcessesProtocol
import SwiftTerm

enum Palette {
    static let shell = Color(red: 0.095, green: 0.105, blue: 0.11)
    static let sidebar = Color(red: 0.12, green: 0.13, blue: 0.135)
    static let panel = Color(red: 0.105, green: 0.115, blue: 0.12)
    static let line = Color.white.opacity(0.08)
    static let muted = Color(red: 0.61, green: 0.65, blue: 0.65)
    static let mint = Color(red: 0.48, green: 0.82, blue: 0.69)
    static func status(_ value: String) -> SwiftUI.Color {
        switch value {
        case "running", "starting": return mint
        case "completed": return Color(red: 0.55, green: 0.75, blue: 0.64)
        case "failed": return .orange
        default: return .gray
        }
    }
}

extension Service {
    var visiblePorts: [Int] { (ports?.isEmpty == false ? ports : port.map { [$0] }) ?? [] }
}

@MainActor final class AppModel: ObservableObject {
    @Published var services: [Service] = []
    @Published var aiConnections: [AIConnection] = []
    @Published var selectedID: String?
    @Published var daemonPID: Int32?
    @Published var connectionError: String?
    @Published var error: String?
    @Published var terminalGeneration = UUID()
    @Published var showingAdd = false
    @Published var showingAbout = false
    @Published var showingConnections = false
    @Published var showingSSH = false
    @Published var showingAppearance = false
    @Published var showingUpdates = false
    @Published var showingGit = false
    @Published var tabs: [TerminalTab] = []
    @Published var activeTabID: UUID?
    @Published var focusedPaneID: UUID?
    @Published var terminalRenderers: [UUID: String] = [:]
    weak var terminal: TerminalView?
    private let queue = DispatchQueue(label: "Processes.client", qos: .userInitiated)
    private let client = RuntimeClient()
    private var polling = false
    private var timer: Timer?
    var selected: Service? { services.first { $0.id == selectedID } }

    init() {
        let executable = Self.helperURL()
        queue.async { [client] in
            do { try client.ensureDaemon(executableURL: executable) }
            catch { DispatchQueue.main.async { self.connectionError = "Could not start the daemon: \(error.localizedDescription)" } }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        poll()
        Task { await AppUpdates.shared.checkIfDue() }
    }
    static func helperURL() -> URL {
        if let bundle = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundleURL as URL? : nil {
            return bundle.appendingPathComponent("Contents/Helpers/rundock")
        }
        return URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("processes")
    }
    func select(_ id: String?) {
        showingGit = false
        guard let id else { selectedID = nil; terminal = nil; return }
        if let index = tabs.firstIndex(where: { $0.panes.contains(where: { $0.serviceID == id }) }) {
            activeTabID = tabs[index].id
            focusedPaneID = tabs[index].panes.first { $0.serviceID == id }?.id
        } else {
            let pane = TerminalPane(serviceID: id)
            let tab = TerminalTab(panes: [pane])
            tabs.append(tab); activeTabID = tab.id; focusedPaneID = pane.id
        }
        selectedID = id; terminal = nil; saveLayout()
    }
    func resetTerminal() { terminalGeneration = UUID(); terminal = nil }
    func poll() {
        guard !polling else { return }
        polling = true
        queue.async { [client] in
            let result = Result { () -> Response in
                let ping = try client.send(Request("ping"))
                guard (ping.protocolVersion ?? 1) >= 5 else { throw RuntimeError("Stop the older daemon’s services, then restart it to enable streaming and task workspaces. Running jobs are preserved until you stop them.") }
                var list = try client.send(Request("list")); list.daemonPID = ping.daemonPID
                list.connections = try client.send(Request("ai-connections")).connections
                return list
            }
            DispatchQueue.main.async {
                self.polling = false
                switch result {
                case .failure(let error): self.daemonPID = nil; self.connectionError = error.localizedDescription; self.aiConnections = []
                case .success(let list):
                    let services = list.services ?? []
                    if self.services != services { self.services = services }
                    if self.daemonPID != list.daemonPID { self.daemonPID = list.daemonPID }
                    if self.connectionError != nil { self.connectionError = nil }
                    let connections = list.connections ?? []
                    if self.aiConnections != connections { self.aiConnections = connections }
                    if !self.restoredLayout { self.restoreLayout() }
                    let ids = Set(self.services.map(\.id))
                    let validTabs = self.tabs.compactMap { tab -> TerminalTab? in
                        var value = tab; value.panes.removeAll { !ids.contains($0.serviceID) }; return value.panes.isEmpty ? nil : value
                    }
                    if self.tabs != validTabs { self.tabs = validTabs }
                    if let selected = self.selectedID, !ids.contains(selected) { self.selectedID = nil }
                    if self.selectedID == nil, !self.userClosedAllTabs, let newest = self.services.max(by: { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }) { self.select(newest.id) }
                }
            }
        }
    }
    private var restoredLayout = false
    private var userClosedAllTabs = false
    private func restoreLayout() {
        restoredLayout = true
        guard let data = UserDefaults.standard.data(forKey: "terminalLayout"), let saved = try? JSONDecoder().decode([TerminalTab].self, from: data) else { return }
        tabs = saved
        if let first = tabs.first, let pane = first.panes.first { activeTabID = first.id; focusedPaneID = pane.id; selectedID = pane.serviceID }
    }
    func saveLayout() { if let data = try? JSONEncoder().encode(tabs) { UserDefaults.standard.set(data, forKey: "terminalLayout") } }
    func activateTab(_ tab: TerminalTab) {
        activeTabID = tab.id
        if let pane = tab.panes.first { selectedID = pane.serviceID; focusedPaneID = pane.id }
        terminal = nil
    }
    func focusPane(_ pane: TerminalPane, terminal: TerminalView? = nil) {
        if focusedPaneID != pane.id { focusedPaneID = pane.id }
        if selectedID != pane.serviceID { selectedID = pane.serviceID }
        if let terminal { self.terminal = terminal }
    }
    func closeTab(_ id: UUID) {
        tabs.removeAll { $0.id == id }; userClosedAllTabs = tabs.isEmpty
        if activeTabID == id { if let tab = tabs.last { activateTab(tab) } else { activeTabID = nil; selectedID = nil; terminal = nil } }
        saveLayout()
    }
    func closePane(_ pane: TerminalPane, tabID: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[i].panes.removeAll { $0.id == pane.id }
        if tabs[i].panes.isEmpty { closeTab(tabID) } else { activateTab(tabs[i]); saveLayout() }
    }
    func newTerminal(split: Bool = false, horizontal: Bool = true, command: String? = nil, name: String? = nil) {
        let taskID = name == nil ? selected?.taskID : nil
        let cwd = (name == nil ? selected?.cwd : nil) ?? FileManager.default.homeDirectoryForCurrentUser.path
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let command = command ?? "exec '" + shell.replacingOccurrences(of: "'", with: "'\\''") + "' -l"
        let baseName = name ?? "Shell"
        var sessionName = baseName, number = 2
        while services.contains(where: { $0.cwd == cwd && $0.name == sessionName }) {
            sessionName = "\(baseName) \(number)"; number += 1
        }
        let service = Service(project: name == nil ? "Terminals" : "SSH", name: sessionName, command: command, cwd: cwd)
        send(Request("add", service: service, actor: "User", taskID: taskID)) { added in
            guard added else { return }
            self.send(Request("start", id: service.id, actor: "User")) { started in
                guard started else { return }
                self.userClosedAllTabs = false
                if split, let i = self.tabs.firstIndex(where: { $0.id == self.activeTabID }), self.tabs[i].panes.count < 4 {
                    let pane = TerminalPane(serviceID: service.id); self.tabs[i].panes.append(pane); self.tabs[i].horizontal = horizontal; self.focusedPaneID = pane.id; self.selectedID = service.id; self.saveLayout()
                } else { self.select(service.id) }
            }
        }
    }
    func openTaskTerminal(_ task: GitTask) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let command = "exec '" + shell.replacingOccurrences(of: "'", with: "'\\''") + "' -l"
        let service = Service(project: task.name, name: "Task Shell", command: command, cwd: task.worktreePath, branch: task.branch)
        queue.async { [client] in
            let result = Result { try client.send(Request("run", service: service, actor: "User", taskID: task.id)) }
            DispatchQueue.main.async {
                switch result {
                case .success(let response):
                    if let service = response.services?.first {
                        if let i = self.services.firstIndex(where: { $0.id == service.id }) { self.services[i] = service }
                        else { self.services.append(service) }
                        self.userClosedAllTabs = false; self.select(service.id); self.poll()
                    }
                case .failure(let error): self.error = error.localizedDescription
                }
            }
        }
    }
    func send(_ request: Request, reset: Bool = false, completion: ((Bool) -> Void)? = nil) {
        if request.action == "resize" {
            queue.async { [client] in _ = try? client.send(request) }
            return
        }
        if reset { resetTerminal() }
        queue.async { [client] in
            let result = Result { try client.send(request) }
            DispatchQueue.main.async {
                switch result {
                case .failure(let error): self.error = error.localizedDescription; completion?(false)
                case .success(let response):
                    if !response.ok { self.error = response.error ?? "The operation failed." }
                    if let services = response.services { self.services = services }
                    if response.ok, (request.action == "start" || request.action == "restart"), let id = request.id, let terminal = self.terminal {
                        let dimensions = terminal.getTerminal().getDims()
                        self.send(Request("resize", id: id, columns: UInt16(clamping: dimensions.cols), rows: UInt16(clamping: dimensions.rows)))
                    }
                    completion?(response.ok)
                    self.poll()
                }
            }
        }
    }
    func action(_ action: String, reset: Bool = false) {
        guard let id = selectedID else { return }
        send(Request(action, id: id, actor: "User"), reset: reset)
    }
    func focusTerminal() {
        guard let terminal else { return }
        terminal.window?.makeFirstResponder(terminal)
    }
    func stopAllAndQuit() {
        let ids = services.filter { $0.status == "running" }.map(\.id)
        queue.async { [client] in
            var failures: [String] = []
            for id in ids {
                do { _ = try client.send(Request("stop", id: id, actor: "User")) }
                catch { failures.append("\(id): \(error.localizedDescription)") }
            }
            DispatchQueue.main.async {
                if failures.isEmpty { NSApplication.shared.terminate(nil) }
                else { self.error = "Could not stop every service. The app remains open.\n" + failures.joined(separator: "\n"); self.poll() }
            }
        }
    }
    enum ClientError: LocalizedError { case message(String); var errorDescription: String? { if case .message(let value) = self { return value }; return nil } }
}

@main struct ProcessesApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("RunDock") {
            RootView().environmentObject(model)
                .frame(minWidth: 1000, minHeight: 650)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1250, height: 800)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About RunDock") { model.showingAbout = true }
                Button("Check for Updates…") { model.showingUpdates = true }
            }
            CommandGroup(after: .newItem) {
                Button("Add Service…") { model.showingAdd = true }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Connect AI…") { model.showingConnections = true }
                Button("AI Tasks & Git") { model.showingGit = true }
                Button("New Terminal Tab") { model.newTerminal() }.keyboardShortcut("t", modifiers: .command)
                Button("Split Vertically") { model.newTerminal(split: true) }.keyboardShortcut("d", modifiers: .command)
                Button("Split Horizontally") { model.newTerminal(split: true, horizontal: false) }.keyboardShortcut("d", modifiers: [.command, .shift])
                Button("SSH Hosts…") { model.showingSSH = true }
                Button("Terminal Appearance…") { model.showingAppearance = true }
            }
            CommandGroup(after: .appTermination) {
                Button("Stop All and Quit") { model.stopAllAndQuit() }
                Button("Focus Terminal") { model.focusTerminal() }.keyboardShortcut("l", modifiers: .command).disabled(model.selectedID == nil)
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Sidebar().frame(width: 225)
                    Rectangle().fill(Palette.line).frame(width: 1)
                    if model.showingGit {
                        GitWorkspaceView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        MainPane().frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    if !model.showingGit && geometry.size.width >= 1100 {
                        Rectangle().fill(Palette.line).frame(width: 1)
                        Inspector().frame(width: 260)
                    }
                }
                Rectangle().fill(Palette.line).frame(height: 1)
                statusBar
            }.background(Palette.shell)
        }
        .sheet(isPresented: $model.showingAdd) { AddServiceView() }
        .sheet(isPresented: $model.showingAbout) { AboutView() }
        .sheet(isPresented: $model.showingConnections) { AIConnectionsView() }
        .sheet(isPresented: $model.showingSSH) { SSHWorkspaceView { name, command in model.newTerminal(command: command, name: name) } }
        .sheet(isPresented: $model.showingAppearance) { TerminalAppearanceView() }
        .sheet(isPresented: $model.showingUpdates) { AppUpdatesView() }
        .alert("RunDock", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    var statusBar: some View {
        HStack(spacing: 8) {
            Circle().fill(model.daemonPID == nil ? Color.orange : Palette.mint).frame(width: 6, height: 6)
            Text(model.daemonPID == nil ? "Daemon disconnected · retrying" : "Daemon connected").help(model.connectionError ?? "Daemon connected")
            if let pid = model.daemonPID { Text("·  PID \(pid)").foregroundStyle(Palette.muted) }
            Text("·  \(model.aiConnections.filter { $0.isConnected }.count) AI connected").foregroundStyle(Palette.muted)
            Spacer()
            Text("\(model.services.filter { $0.status == "running" }.count) running")
        }.font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.horizontal, 18).frame(height: 31).background(Palette.sidebar)
    }
}

struct Sidebar: View {
    @EnvironmentObject var model: AppModel
    @State private var removing: Service?
    var groups: [String] { Array(Set(model.services.map(\.project))).sorted() }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("WORKSPACE").font(.system(size: 10, weight: .semibold)).tracking(1.1).foregroundStyle(Palette.muted)
                Spacer()
                Button { model.showingAdd = true } label: { Image(systemName: "plus") }.buttonStyle(.plain).help("Add Service").accessibilityLabel("Add Service")
            }.padding(.horizontal, 17).padding(.top, 24).padding(.bottom, 17)
            if groups.isEmpty {
                Text("Your services will appear here.").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.horizontal, 17)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 19) {
                        ForEach(groups, id: \.self) { group in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack(spacing: 7) { Image(systemName: "folder"); Text(group).lineLimit(1); Spacer() }
                                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted).padding(.horizontal, 11).padding(.bottom, 3)
                                ForEach(model.services.filter { $0.project == group }) { service in
                                    Button { model.select(service.id) } label: {
                                        HStack(spacing: 9) {
                                            Circle().fill(Palette.status(service.status)).frame(width: 6, height: 6)
                                            Text(service.name).lineLimit(1)
                                            Spacer(minLength: 2)
                                            if let port = service.visiblePorts.first { Text(String(port)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted) }
                                        }.font(.system(size: 12, weight: model.selectedID == service.id ? .medium : .regular))
                                            .padding(.horizontal, 11).frame(height: 30).contentShape(Rectangle())
                                            .background(model.selectedID == service.id ? Color.white.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 6))
                                    }.buttonStyle(.plain).accessibilityLabel("\(service.name), \(service.status)")
                                    .contextMenu {
                                        Button("Remove Service…", role: .destructive) { removing = service }.disabled(service.status == "running")
                                    }
                                }
                            }
                        }
                    }.padding(.horizontal, 8)
                }
            }
            Spacer(minLength: 0)
            Button { model.showingGit = true } label: { Label("AI Tasks & Git", systemImage: "arrow.triangle.branch").frame(maxWidth: .infinity, alignment: .leading) }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(model.showingGit ? Palette.mint : .primary).padding(.horizontal, 17).padding(.vertical, 10)
            Button { model.newTerminal() } label: { Label("New Terminal", systemImage: "terminal").frame(maxWidth: .infinity, alignment: .leading) }
                .buttonStyle(.plain).font(.system(size: 12)).padding(.horizontal, 17).padding(.vertical, 10)
            Button { model.showingSSH = true } label: { Label("SSH Hosts & SFTP", systemImage: "network").frame(maxWidth: .infinity, alignment: .leading) }
                .buttonStyle(.plain).font(.system(size: 12)).padding(.horizontal, 17).padding(.vertical, 10)
            Button { model.showingAppearance = true } label: { Label("Terminal Appearance", systemImage: "paintpalette").frame(maxWidth: .infinity, alignment: .leading) }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.horizontal, 17).padding(.vertical, 10)
            Button { model.showingConnections = true } label: { Label("Connect AI", systemImage: "point.3.connected.trianglepath.dotted").frame(maxWidth: .infinity, alignment: .leading) }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.mint).padding(.horizontal, 17).padding(.vertical, 12)
            Button { model.showingAdd = true } label: { Label("Add Service", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading) }
                .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.muted).padding(17)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Palette.sidebar)
        .alert("Remove Service?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Cancel", role: .cancel) { removing = nil }
            Button("Remove", role: .destructive) {
                if let service = removing { model.send(Request("remove", id: service.id, actor: "User")) }
                removing = nil
            }
        } message: { Text("Remove \(removing?.name ?? "this service") and its saved output?") }
    }
}

struct MainPane: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "terminal").foregroundStyle(Palette.mint)
                Text(model.selected?.name ?? "RunDock").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if let service = model.selected { Text(service.project).font(.system(size: 11)).foregroundStyle(Palette.muted) }
                Spacer()
                if let service = model.selected {
                    if service.taskID != nil {
                        Button { model.showingGit = true } label: { Label("Git", systemImage: "arrow.triangle.branch") }
                    }
                    if let port = service.visiblePorts.first {
                        Button { if let url = URL(string: "http://localhost:\(port)") { NSWorkspace.shared.open(url) } } label: { Label("Open", systemImage: "arrow.up.right") }
                            .help("Open localhost:\(port)")
                    }
                    Button { model.action("restart", reset: true) } label: { Label("Restart", systemImage: "arrow.clockwise") }
                    Button { model.action(service.status == "running" ? "stop" : "start", reset: service.status != "running") } label: {
                        Label(service.status == "running" ? "Stop" : "Start", systemImage: service.status == "running" ? "stop.fill" : "play.fill")
                    }
                }
            }.buttonStyle(ToolbarButtonStyle()).padding(.horizontal, 20).frame(height: 57)
            Rectangle().fill(Palette.line).frame(height: 1)
            if let tab = model.tabs.first(where: { $0.id == model.activeTabID }) {
                TerminalWorkspaceView(tab: tab)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "terminal").font(.system(size: 28, weight: .light)).foregroundStyle(Palette.mint)
                    Text("Your AI runs it. You stay in control.").font(.system(size: 18, weight: .semibold))
                    Text("Connect your AI tool once. Commands appear here as they run.").font(.system(size: 13)).foregroundStyle(Palette.muted)
                    Button("Connect AI") { model.showingConnections = true }.buttonStyle(MintButtonStyle()).padding(.top, 5)
                    Button("Add a service manually") { model.showingAdd = true }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Palette.muted)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(Palette.shell)
    }
}
struct MintButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .semibold)).foregroundColor(.black)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Palette.mint.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 6))
    }
}
struct ToolbarButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11, weight: .medium)).padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.white.opacity(configuration.isPressed ? 0.13 : 0.065), in: RoundedRectangle(cornerRadius: 6))
    }
}

struct Inspector: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("DETAILS").font(.system(size: 10, weight: .semibold)).tracking(1.1).foregroundStyle(Palette.muted).padding(.horizontal, 20).frame(height: 57, alignment: .leading)
            Rectangle().fill(Palette.line).frame(height: 1)
            if let service = model.selected {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 9) { Circle().fill(Palette.status(service.status)).frame(width: 7, height: 7); Text(service.name).font(.system(size: 15, weight: .semibold)).lineLimit(1) }
                        Text(service.status.capitalized).font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.top, 6)
                        Rectangle().fill(Palette.line).frame(height: 1).padding(.vertical, 20)
                        HStack {
                            Text("Started by").foregroundStyle(Palette.muted)
                            Spacer()
                            if let clientID = AIClientIcon.clientID(for: service.startedBy) { AIClientIcon(clientID: clientID, size: 18) }
                            Text(service.startedBy).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }.font(.system(size: 12)).padding(.bottom, 15)
                        detail("Branch", service.branch ?? "—")
                        detail("PID", service.pid.map(String.init) ?? "—")
                        detail("Ports", service.visiblePorts.isEmpty ? "—" : service.visiblePorts.map(String.init).joined(separator: ", "))
                        if let started = service.startedAt, service.status == "running" {
                            HStack { Text("Uptime").foregroundStyle(Palette.muted); Spacer(); Text(started, style: .relative).monospacedDigit() }.font(.system(size: 12)).padding(.bottom, 15)
                        } else { detail("Uptime", "—") }
                        if service.status != "running", let exitCode = service.exitCode { detail("Exit code", String(exitCode)) }
                        if let ended = service.endedAt {
                            HStack { Text("Finished").foregroundStyle(Palette.muted); Spacer(); Text(ended, style: .relative) }.font(.system(size: 12)).padding(.bottom, 15)
                        }
                        Rectangle().fill(Palette.line).frame(height: 1).padding(.vertical, 8)
                        Text("COMMAND").font(.system(size: 10, weight: .semibold)).tracking(1.1).foregroundStyle(Palette.muted).padding(.top, 16).padding(.bottom, 10)
                        Text(service.command).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).help(service.command)
                        Text("WORKING DIRECTORY").font(.system(size: 10, weight: .semibold)).tracking(1.1).foregroundStyle(Palette.muted).padding(.top, 18).padding(.bottom, 10)
                        Text(service.cwd).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).help(service.cwd)
                        Rectangle().fill(Palette.line).frame(height: 1).padding(.top, 20).padding(.bottom, 8)
                        Text("ACTIVITY").font(.system(size: 10, weight: .semibold)).tracking(1.1).foregroundStyle(Palette.muted).padding(.top, 16).padding(.bottom, 15)
                        if service.events.isEmpty { Text("No activity yet.").font(.system(size: 12)).foregroundStyle(Palette.muted) }
                        ForEach(Array(service.events.reversed().enumerated()), id: \.offset) { _, event in
                            HStack(alignment: .top, spacing: 9) {
                                Circle().fill(Palette.mint.opacity(0.75)).frame(width: 5, height: 5).padding(.top, 5)
                                VStack(alignment: .leading, spacing: 4) { Text(event.message).font(.system(size: 12)); Text(event.date, style: .relative).font(.system(size: 10)).foregroundStyle(Palette.muted) }
                            }.padding(.bottom, 17)
                        }
                    }.padding(20)
                }
            } else { Text("Select a service to see its details.").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(20) }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).background(Palette.panel)
    }
    func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) { Text(label).foregroundStyle(Palette.muted); Spacer(); Text(value).lineLimit(1).truncationMode(.middle).textSelection(.enabled) }.font(.system(size: 12)).padding(.bottom, 15)
    }
}

struct AddServiceView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var project = ""
    @State private var name = ""
    @State private var cwd = ""
    @State private var command = ""
    @State private var port = ""
    @State private var validation: String?
    @State private var saving = false
    @FocusState private var focused: Field?
    enum Field { case project, name, cwd, command, port }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Add Service").font(.system(size: 19, weight: .semibold))
            Text("Register a command to run under RunDock.").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(.top, 6).padding(.bottom, 22)
            Form {
                TextField("Project", text: $project, prompt: Text("e.g. My project")).focused($focused, equals: .project)
                TextField("Service name", text: $name, prompt: Text("e.g. API")).focused($focused, equals: .name)
                HStack {
                    TextField("Working directory", text: $cwd, prompt: Text("Choose a folder")).disabled(true)
                    Button("Choose…") { chooseDirectory() }
                }
                TextField("Command", text: $command, prompt: Text("e.g. npm run dev")).focused($focused, equals: .command)
                TextField("Port (optional)", text: $port, prompt: Text("e.g. 3000")).focused($focused, equals: .port)
            }.formStyle(.automatic)
            Text("Choose the project folder to allow RunDock to access it.")
                .font(.system(size: 11)).foregroundStyle(Palette.muted).padding(.top, 10)
            if let validation { Text(validation).font(.system(size: 12)).foregroundStyle(.red).padding(.top, 12) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(saving ? "Adding…" : "Add Service") { save() }.keyboardShortcut(.defaultAction).disabled(saving)
            }.padding(.top, 22)
        }.padding(26).frame(width: 520).background(Palette.panel).onAppear { focused = .project }
    }
    func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { cwd = url.path }
    }
    func save() {
        let project = project.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !project.isEmpty, !name.isEmpty, !cwd.isEmpty, !command.isEmpty else { validation = "Fill in the project, service name, working directory, and command."; return }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &directory), directory.boolValue else { validation = "Choose an existing working directory."; return }
        let trimmedPort = port.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedPort = Int(trimmedPort)
        guard trimmedPort.isEmpty || (parsedPort != nil && (1...65535).contains(parsedPort!)) else { validation = "Enter a port between 1 and 65535, or leave it empty."; return }
        let service = Service(project: project, name: name, command: command, cwd: cwd, port: parsedPort)
        saving = true
        model.send(Request("add", service: service, actor: "User")) { ok in
            saving = false
            if ok { model.select(service.id); dismiss() }
        }
    }
}


struct AboutView: View {
    @Environment(\.dismiss) private var dismiss
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.4.1" }
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable().interpolation(.high).frame(width: 80, height: 80).accessibilityHidden(true)
            Text("RunDock").font(.system(size: 22, weight: .semibold))
            Text("Version \(version)").font(.system(size: 12)).foregroundStyle(Palette.muted)
            Text("Developer").font(.system(size: 11, weight: .semibold)).foregroundStyle(Palette.muted).padding(.top, 8)
            Text("NEXUS TECHNOLOGY COMPANY LIMITED").font(.system(size: 12))
            Link("nexustecs.com", destination: URL(string: "https://nexustecs.com/")!).font(.system(size: 12))
            Text("Open source · MIT License").font(.system(size: 12)).foregroundStyle(Palette.muted)
            Link("Terminal emulation by SwiftTerm", destination: URL(string: "https://github.com/migueldeicaza/SwiftTerm")!)
                .font(.system(size: 12)).padding(.top, 8)
            HStack(spacing: 12) {
                Button("View Licenses") {
                    if let resources = Bundle.main.resourceURL {
                        NSWorkspace.shared.open(resources.appendingPathComponent("acknowledgments", isDirectory: true))
                    }
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(.top, 14)
        }.padding(28).frame(width: 360).background(Palette.panel)
    }
}
