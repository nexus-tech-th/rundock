import SwiftUI
import AppKit
import ProcessesProtocol

@MainActor final class GitWorkspaceModel: ObservableObject {
    @Published var tasks: [GitTask] = []
    @Published var selectedID: String?
    @Published var changes: [GitChange] = []
    @Published var selectedPath: String?
    @Published var staged = false
    @Published var diff = "Select a changed file to inspect its diff."
    @Published var truncated = false
    @Published var busy = false
    @Published var error: String?
    @Published var notice: String?
    @Published var message = ""
    private let client = RuntimeClient()
    private let queue = DispatchQueue(label: "RunDock.git-ui", qos: .userInitiated)
    private var selectionGeneration = UUID()
    var selected: GitTask? { tasks.first { $0.id == selectedID } }
    var stagedCount: Int { changes.filter { $0.indexStatus != " " && $0.indexStatus != "?" }.count }

    func load(preferredID: String? = nil) {
        perform(Request("task-list")) { response in
            self.tasks = response.tasks ?? []
            let id = preferredID ?? self.selectedID
            self.select(self.tasks.first { $0.id == id }?.id ?? self.tasks.first?.id)
        }
    }
    func select(_ id: String?) {
        selectionGeneration = UUID(); selectedID = id; selectedPath = nil
        changes = []; diff = "Select a changed file to inspect its diff."; truncated = false
        refresh()
    }
    func refresh() {
        guard let id = selectedID else { return }
        let generation = selectionGeneration
        perform(Request("git-status", taskID: id)) { response in
            guard self.selectedID == id, self.selectionGeneration == generation else { return }
            self.changes = response.gitStatus ?? []
            if let path = self.selectedPath, !self.changes.contains(where: { $0.path == path }) { self.selectedPath = nil }
            if self.selectedPath == nil { self.selectedPath = self.changes.first?.path }
            self.loadDiff()
        }
    }
    func loadDiff() {
        guard let id = selectedID, let path = selectedPath else {
            diff = changes.isEmpty ? "Working tree is clean." : "Select a changed file to inspect its diff."
            truncated = false; return
        }
        let generation = selectionGeneration, staged = staged
        diff = "Loading diff…"; truncated = false
        perform(Request("git-diff", taskID: id, paths: [path], staged: staged), showsBusy: false) { response in
            guard self.selectedID == id, self.selectedPath == path, self.staged == staged, self.selectionGeneration == generation else { return }
            self.diff = response.text?.isEmpty == false ? response.text! : "No changes in this view."
            self.truncated = response.truncated == true
        }
    }
    func create(repository: String, name: String, completion: @escaping (Bool) -> Void) {
        perform(Request("task-ensure", taskKey: UUID().uuidString.lowercased(), repositoryPath: repository, taskName: name, clientName: "User"), failure: { completion(false) }) { response in
            guard let task = response.task else { self.error = "The daemon did not return the task workspace."; completion(false); return }
            self.load(preferredID: task.id); completion(true)
        }
    }
    func changeIndex(stage: Bool) {
        guard let id = selectedID, let path = selectedPath else { return }
        let paths = [path] + (changes.first { $0.path == path }?.originalPath.map { [$0] } ?? [])
        perform(Request(stage ? "git-stage" : "git-unstage", taskID: id, paths: paths)) { _ in self.refresh() }
    }
    func commit() {
        guard let id = selectedID else { return }
        perform(Request("git-commit", taskID: id, message: message)) { response in
            self.message = ""; self.notice = response.text ?? "Committed staged changes."; self.refresh()
        }
    }
    func push() {
        guard let id = selectedID else { return }
        perform(Request("git-push", taskID: id)) { response in self.notice = response.text?.isEmpty == false ? response.text : "Push completed."; self.refresh() }
    }
    private func perform(_ request: Request, showsBusy: Bool = true, failure: (() -> Void)? = nil, completion: @escaping (Response) -> Void) {
        if showsBusy { busy = true }; error = nil
        queue.async { [client] in
            let result = Result { try client.send(request) }
            DispatchQueue.main.async {
                if showsBusy { self.busy = false }
                switch result {
                case .success(let response): completion(response)
                case .failure(let error): self.error = error.localizedDescription; failure?()
                }
            }
        }
    }
}

struct GitWorkspaceView: View {
    @EnvironmentObject var app: AppModel
    @StateObject private var git = GitWorkspaceModel()
    @State private var creating = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Label("AI Tasks & Git", systemImage: "point.3.connected.trianglepath.dotted").font(.system(size: 14, weight: .semibold))
                Spacer()
                if git.busy { ProgressView().controlSize(.small) }
                Button("Refresh") { git.load() }.disabled(git.busy)
                Button("New Task…") { creating = true }.disabled(git.busy)
                Button { if let task = git.selected { app.openTaskTerminal(task) } } label: { Label("Terminal", systemImage: "terminal") }.disabled(git.selected == nil)
            }.buttonStyle(ToolbarButtonStyle()).padding(.horizontal, 20).frame(height: 57)
            Divider().overlay(Palette.line)
            if git.tasks.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 28)).foregroundStyle(Palette.mint)
                    Text("A separate workspace for each task").font(.system(size: 18, weight: .semibold))
                    Text("Create a task from a Git repository. RunDock gives it a branch, a worktree and a reusable terminal.").font(.system(size: 13)).foregroundStyle(Palette.muted).multilineTextAlignment(.center).frame(maxWidth: 440)
                    Button("New Task…") { creating = true }.buttonStyle(MintButtonStyle())
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                taskHeader
                if let error = git.error { messageBar(error, error: true) }
                else if let notice = git.notice, !notice.isEmpty { messageBar(notice, error: false) }
                HSplitView {
                    files.frame(minWidth: 190, idealWidth: 240, maxWidth: 320)
                    diff.frame(minWidth: 250, maxWidth: .infinity, maxHeight: .infinity)
                }
                Divider().overlay(Palette.line)
                HStack(spacing: 10) {
                    Text("\(git.stagedCount) staged").font(.system(size: 11)).foregroundStyle(Palette.muted)
                    TextField("Commit message", text: $git.message).textFieldStyle(.roundedBorder).accessibilityLabel("Commit message")
                    Button("Commit Staged") { git.commit() }.disabled(git.busy || git.stagedCount == 0 || git.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(14).background(Palette.panel)
            }
            if git.tasks.isEmpty, let error = git.error { messageBar(error, error: true) }
        }.background(Palette.shell)
        .onAppear { git.load(preferredID: app.selected?.taskID) }
        .sheet(isPresented: $creating) { CreateGitTaskView(git: git) }
    }
    private var taskHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Picker("Task", selection: Binding(get: { git.selectedID ?? "" }, set: { git.select($0) })) {
                    ForEach(git.tasks, id: \.id) { task in Text("\(task.name) · \(task.client)").tag(task.id) }
                }.frame(maxWidth: 420).disabled(git.busy)
                Spacer()
                Button("Reveal Worktree") { if let task = git.selected { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: task.worktreePath) } }.disabled(git.selected == nil)
                Button("Push") { git.push() }.disabled(git.busy || git.selected == nil).help("Push this task branch. No force push.")
            }
            if let task = git.selected {
                Label(task.branch, systemImage: "arrow.triangle.branch").font(.system(size: 12, weight: .medium)).foregroundStyle(Palette.mint).lineLimit(1).truncationMode(.middle).help(task.branch).textSelection(.enabled)
                Text(task.worktreePath).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(2).textSelection(.enabled).help(task.repositoryPath)
            }
        }.padding(.horizontal, 20).padding(.vertical, 14).background(Palette.panel)
    }
    private var files: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("Changes").font(.system(size: 12, weight: .semibold)); Spacer(); Text("\(git.changes.count)").foregroundStyle(Palette.muted) }.padding(12)
            List(selection: $git.selectedPath) {
                ForEach(git.changes, id: \.path) { change in
                    HStack(spacing: 8) {
                        Text(change.indexStatus + change.worktreeStatus).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.mint).frame(width: 24)
                        Text(change.path).font(.system(size: 12)).lineLimit(2).truncationMode(.middle)
                    }.padding(.vertical, 3).tag(change.path).help(change.originalPath.map { "\($0) → \(change.path)" } ?? change.path)
                }
            }.listStyle(.sidebar).onChange(of: git.selectedPath) { _ in git.loadDiff() }
            HStack {
                Button("Stage") { git.changeIndex(stage: true) }.disabled(git.changes.first { $0.path == git.selectedPath }?.worktreeStatus == " ")
                Button("Unstage") { git.changeIndex(stage: false) }.disabled(!git.changes.contains { $0.path == git.selectedPath && $0.indexStatus != " " && $0.indexStatus != "?" })
            }.disabled(git.busy || git.selectedPath == nil).padding(12)
        }.background(Palette.sidebar)
    }
    private var diff: some View {
        VStack(spacing: 0) {
            HStack {
                Text(git.selectedPath ?? "Diff").font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Picker("Diff view", selection: $git.staged) { Text("Working Tree").tag(false); Text("Staged").tag(true) }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }.padding(12).background(Palette.panel)
            NativeGitDiff(text: git.diff).frame(maxWidth: .infinity, maxHeight: .infinity)
            if git.truncated { Text("Diff preview is truncated. The file and Git index are unchanged.").font(.system(size: 11)).foregroundStyle(.orange).padding(8) }
        }.onChange(of: git.staged) { _ in git.loadDiff() }
    }
    private func messageBar(_ text: String, error: Bool) -> some View {
        HStack(alignment: .top) {
            Image(systemName: error ? "exclamationmark.triangle" : "checkmark.circle")
            Text(text).font(.system(size: 12)).textSelection(.enabled).lineLimit(4)
            Spacer()
            Button { git.error = nil; git.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).accessibilityLabel("Dismiss Git message")
        }.foregroundStyle(error ? Color.orange : Palette.mint).padding(12)
    }
}

private struct CreateGitTaskView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var git: GitWorkspaceModel
    @State private var name = ""
    @State private var repository = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Task Workspace").font(.system(size: 20, weight: .semibold))
            Text("Create an isolated branch and worktree from an existing local Git repository.").font(.system(size: 13)).foregroundStyle(Palette.muted)
            VStack(alignment: .leading, spacing: 7) { Text("Task name"); TextField("Fix login, add search…", text: $name).textFieldStyle(.roundedBorder).accessibilityLabel("Task name") }
            VStack(alignment: .leading, spacing: 7) {
                Text("Repository")
                HStack {
                    TextField("/path/to/repository", text: $repository).textFieldStyle(.roundedBorder).accessibilityLabel("Repository path")
                    Button("Choose…") {
                        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url { repository = url.path }
                    }
                }
            }
            if let error = git.error { Text(error).font(.system(size: 12)).foregroundStyle(.orange).textSelection(.enabled) }
            HStack { Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(git.busy)
                Button("Create Workspace") { git.create(repository: repository, name: name) { if $0 { dismiss() } } }.keyboardShortcut(.defaultAction).disabled(git.busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || repository.isEmpty)
            }
        }.font(.system(size: 13)).padding(28).frame(width: 520).background(Palette.shell)
    }
}

private struct NativeGitDiff: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        let view = NSTextView(); view.isEditable = false; view.isSelectable = true; view.isRichText = false
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular); view.textColor = .textColor; view.backgroundColor = NSColor(red: 0.095, green: 0.105, blue: 0.11, alpha: 1)
        view.textContainerInset = NSSize(width: 14, height: 12); view.isHorizontallyResizable = true; view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = false; view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.autoresizingMask = [.width]; view.setAccessibilityLabel("Git diff")
        scroll.documentView = view; return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text; view.scrollToBeginningOfDocument(nil)
    }
}
