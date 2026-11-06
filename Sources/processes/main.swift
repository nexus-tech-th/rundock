import Foundation
import Darwin
import ProcessesProtocol
import ProcessesRuntime

struct Arguments {
    var values: [String]
    mutating func option(_ name: String) throws -> String? {
        guard let index = values.firstIndex(of: name) else { return nil }
        guard index + 1 < values.count, !values[index + 1].hasPrefix("--") else { throw RuntimeError("Missing value for \(name)") }
        let value = values[index + 1]; values.removeSubrange(index...index + 1); return value
    }
    mutating func flag(_ name: String) -> Bool {
        guard let index = values.firstIndex(of: name) else { return false }
        values.remove(at: index); return true
    }
    mutating func required(_ name: String) throws -> String {
        guard let value = try option(name), !value.isEmpty else { throw RuntimeError("Required: \(name)") }; return value
    }
    mutating func id() throws -> String {
        guard !values.isEmpty, !values[0].hasPrefix("--") else { throw RuntimeError("A service ID is required; see `rundock list`") }
        return values.removeFirst()
    }
    func finish() throws { if !values.isEmpty { throw RuntimeError("Unexpected arguments: \(values.joined(separator: " "))") } }
}

let help = """
RunDock 0.4.1 — shared native dev processes for humans and AI

  rundock run [--task ID] [--cwd DIR] [--name NAME] [--actor NAME] [--wait] [--json] [--new] -- program args...
  rundock run [--task ID] [--cwd DIR] [--name NAME] [--actor NAME] [--wait] [--json] [--new] --command SHELL_STRING
  rundock shell [--task ID] [--cwd DIR] [--actor NAME] [--json | --attach]
  rundock task ensure --repo ABS --task STABLE_KEY --name NAME --client NAME [--json]
  rundock task list [--json]
  rundock git status|push --task ID [--json]
  rundock git diff --task ID --path PATH [--staged] [--json]
  rundock git stage|unstage --task ID --path PATH [--path PATH ...] [--json]
  rundock git commit --task ID --message TEXT [--json]
  rundock mcp                    MCP server over stdio
  rundock list [--json]
  rundock add --project NAME --name NAME --cwd ABS --command COMMAND
                [--port PORT] [--actor NAME] [--branch NAME]
  rundock start|stop|restart|remove ID [--actor NAME]
  rundock logs ID [--follow]
  rundock attach ID              Interactive terminal (detach with Ctrl-])
  rundock input ID --text TEXT   Send exact text (include newline if needed)
  rundock resize ID --cols N --rows N
  rundock event ID --message TEXT [--actor NAME]
  rundock daemon start|status|stop [--stop-services]
  rundock skill install --path DIRECTORY

Service commands use the same daemon as RunDock.app. Servers stay running
after this command or the app exits. `daemon stop` refuses running services
unless --stop-services is explicitly supplied. State: PROCESSES_HOME or
~/Library/Application Support/RunDock. No TCP control port or web UI.
"""

let client = RuntimeClient()
let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()

func ready() throws { try client.ensureDaemon(executableURL: executable) }
func emit(_ response: Response, json: Bool = false) throws {
    if json {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        print(String(decoding: try encoder.encode(response), as: UTF8.self)); return
    }
    if let task = response.task {
        print("\(task.id)  \(task.name)  \(task.branch)\n\(task.worktreePath)"); return
    }
    if let tasks = response.tasks {
        if tasks.isEmpty { print("No task worktrees.") }
        for task in tasks { print("\(task.id)  \(task.name)  \(task.branch)\n\(task.worktreePath)") }
        return
    }
    if let changes = response.gitStatus {
        if changes.isEmpty { print("Working tree clean") }
        for change in changes { print("\(change.indexStatus)\(change.worktreeStatus) \(change.path.debugDescription)") }
        return
    }
    if let text = response.text {
        print(text, terminator: text.hasSuffix("\n") ? "" : "\n")
        if response.truncated == true { print("[Output truncated]") }
        return
    }
    guard let services = response.services else { print("OK"); return }
    if services.isEmpty { print("No services. Add one with `rundock add --help` (see `rundock help`)."); return }
    for item in services {
        let detected = (item.ports?.isEmpty == false ? item.ports : item.port.map { [$0] }) ?? []
        let port = detected.isEmpty ? "—" : detected.map { ":\($0)" }.joined(separator: ",")
        print("\(item.id)  \(item.status.padding(toLength: 9, withPad: " ", startingAt: 0))  \(item.project)/\(item.name)  \(port)  pid=\(item.pid.map(String.init) ?? "—")")
    }
}

func copySkill(to directory: String) throws {
    let candidates = [
        executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/skills/rundock"),
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("skills/rundock")
    ]
    guard let source = candidates.first(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("SKILL.md").path) }) else { throw RuntimeError("Bundled skill not found. Run this from the source repository or use the app's bundled CLI.") }
    let target = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("rundock", isDirectory: true)
    guard !FileManager.default.fileExists(atPath: target.path) else { throw RuntimeError("\(target.path) already exists; inspect it before replacing") }
    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: source, to: target)
    print("Installed skill: \(target.path)")
}

@discardableResult
func stream(id: String, interactive: Bool) throws -> Int32 {
    var offset: UInt64 = 0
    var old = termios()
    let raw = interactive && isatty(STDIN_FILENO) != 0
    if raw {
        tcgetattr(STDIN_FILENO, &old); var next = old; cfmakeraw(&next); tcsetattr(STDIN_FILENO, TCSANOW, &next)
    }
    defer { if raw { tcsetattr(STDIN_FILENO, TCSANOW, &old) } }
    var previousColumns: UInt16 = 0; var previousRows: UInt16 = 0
    var inputOpen = interactive
    while true {
        if interactive {
            var size = winsize()
            if ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_col > 0 && size.ws_row > 0 && (size.ws_col != previousColumns || size.ws_row != previousRows) {
                _ = try client.send(Request("resize", id: id, columns: size.ws_col, rows: size.ws_row))
                previousColumns = size.ws_col; previousRows = size.ws_row
            }
        }
        let response = try client.send(Request("read", id: id, offset: offset))
        if let bytes = response.data, !bytes.isEmpty { FileHandle.standardOutput.write(bytes) }
        offset = response.offset ?? offset
        if inputOpen {
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 0) > 0 {
                var buffer = [UInt8](repeating: 0, count: 4096)
                let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                if count > 0 {
                    let data = Data(buffer.prefix(count))
                    if raw, let escape = data.firstIndex(of: 0x1d) {
                        if escape > data.startIndex { _ = try client.send(Request("input", id: id, data: data.prefix(upTo: escape))) }
                        return 0
                    }
                    _ = try client.send(Request("input", id: id, data: data))
                } else { inputOpen = false }
            }
        }
        let services = try client.send(Request("list")).services ?? []
        guard let service = services.first(where: { $0.id == id }) else { throw RuntimeError("Service no longer exists") }
        if !["running", "starting", "stopping"].contains(service.status), (response.data?.isEmpty ?? true) { return service.exitCode ?? (service.status == "completed" ? 0 : 1) }
        Thread.sleep(forTimeInterval: 0.08)
    }
}

func run() throws {
    var args = Arguments(values: Array(CommandLine.arguments.dropFirst()))
    guard !args.values.isEmpty else { print(help); return }
    let command = args.values.removeFirst()
    if command == "_exec" { try RuntimeServer.runChildHelper(arguments: args.values); return }
    if command == "mcp" { if args.values == ["--help"] { print("Usage: rundock mcp (MCP JSON-RPC over stdin/stdout)"); return }; try args.finish(); try runMCP(); return }
    if command == "run" { try autoRun(args.values); return }
    if command == "shell" { if args.values == ["--help"] { print(help); return }; try shellCommand(args.values); return }
    if ["help", "--help", "-h"].contains(command) || args.flag("--help") { print(help); return }
    if command == "--version" { print("0.4.1"); return }
    if command == "daemon" {
        let action = try args.id()
        let stopServices = args.flag("--stop-services"); try args.finish()
        switch action {
        case "run":
            guard !stopServices else { throw RuntimeError("Unexpected --stop-services") }
            _ = setsid()
            signal(SIGPIPE, SIG_IGN)
            try RuntimeServer.run()
        case "start": try ready(); print("Daemon running")
        case "status":
            let response = try client.send(Request("ping")); print("Daemon running (pid \(response.daemonPID.map(String.init) ?? "unknown"))")
        case "stop":
            if stopServices {
                for service in try client.send(Request("list")).services ?? [] { _ = try client.send(Request("stop", id: service.id, actor: "CLI")) }
            }
            _ = try client.send(Request("shutdown")); print("Daemon stopped")
        default: throw RuntimeError("Unknown daemon action: \(action)")
        }
        return
    }
    if command == "skill" {
        guard try args.id() == "install" else { throw RuntimeError("Use `rundock skill install --path DIRECTORY`") }
        let path = try args.required("--path"); try args.finish(); try copySkill(to: path); return
    }
    let json = args.flag("--json")
    switch command {
    case "task":
        let action = try args.id()
        var request: Request
        switch action {
        case "list": request = Request("task-list")
        case "ensure":
            let repository = try args.required("--repo"), key = try args.required("--task")
            guard repository.hasPrefix("/") else { throw RuntimeError("--repo must be an absolute Git directory") }
            request = Request("task-ensure", taskKey: key, repositoryPath: repository, taskName: try args.required("--name"), clientName: try args.required("--client"))
        default: throw RuntimeError("Use `rundock task ensure|list`; see `rundock help`")
        }
        try args.finish(); try ready(); try emit(client.send(request), json: json)
    case "git":
        let action = try args.id()
        guard ["status", "diff", "stage", "unstage", "commit", "push"].contains(action) else { throw RuntimeError("Unknown Git action: \(action)") }
        let taskID = try args.required("--task")
        var request = Request("git-\(action)", taskID: taskID)
        if action == "diff" { request.staged = args.flag("--staged") }
        if ["diff", "stage", "unstage"].contains(action) {
            var paths: [String] = []
            while let path = try args.option("--path") {
                guard !path.isEmpty else { throw RuntimeError("--path must not be empty") }; paths.append(path)
            }
            if ["stage", "unstage"].contains(action), paths.isEmpty { throw RuntimeError("\(action) requires --path PATH (repeat for multiple paths)") }
            if !paths.isEmpty { request.paths = paths }
        }
        if action == "commit" { request.message = try args.required("--message") }
        try args.finish(); try ready(); try emit(client.send(request), json: json)
    case "list": try args.finish(); try ready(); try emit(client.send(Request("list")), json: json)
    case "add":
        let project = try args.required("--project"), name = try args.required("--name"), cwd = try args.required("--cwd"), value = try args.required("--command")
        let actor = try args.option("--actor") ?? "CLI", branch = try args.option("--branch")
        let portText = try args.option("--port")
        let port = portText.flatMap(Int.init)
        if portText != nil && (port == nil || !(1...65535).contains(port!)) { throw RuntimeError("Port must be between 1 and 65535") }
        try args.finish(); try ready()
        let service = Service(project: project, name: name, command: value, cwd: cwd, port: port, startedBy: actor, branch: branch)
        try emit(client.send(Request("add", service: service)), json: json)
    case "start", "stop", "restart", "remove":
        let id = try args.id(), actor = try args.option("--actor") ?? "CLI"; try args.finish(); try ready()
        try emit(client.send(Request(command, id: id, actor: actor)), json: json)
    case "logs", "attach":
        let id = try args.id(); let follow = args.flag("--follow"); try args.finish(); try ready()
        if command == "attach" || follow { try stream(id: id, interactive: command == "attach") }
        else {
            var offset: UInt64 = 0
            while true {
                let response = try client.send(Request("read", id: id, offset: offset))
                guard let data = response.data, !data.isEmpty else { break }
                FileHandle.standardOutput.write(data)
                let next = response.offset ?? offset
                if next <= offset { break }; offset = next
            }
        }
    case "input":
        let id = try args.id(), value = try args.required("--text"); try args.finish(); try ready()
        _ = try client.send(Request("input", id: id, data: Data(value.utf8)))
    case "resize":
        let id = try args.id(), cols = try args.required("--cols"), rows = try args.required("--rows"); try args.finish()
        guard let c = UInt16(cols), let r = UInt16(rows), c > 0, r > 0 else { throw RuntimeError("Rows and columns must be 1...65535") }
        try ready(); _ = try client.send(Request("resize", id: id, columns: c, rows: r))
    case "event":
        let id = try args.id(), value = try args.required("--message"), actor = try args.option("--actor") ?? "CLI"; try args.finish(); try ready()
        _ = try client.send(Request("event", id: id, data: Data(value.utf8), actor: actor))
    default: throw RuntimeError("Unknown command: \(command). Run `rundock help`.")
    }
}

do { try run() }
catch { FileHandle.standardError.write(Data("rundock: \(error.localizedDescription)\n".utf8)); exit(1) }
