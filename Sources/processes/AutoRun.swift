import Foundation
import Darwin
import ProcessesProtocol
import ProcessesRuntime

private func git(_ arguments: [String], cwd: String) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", cwd] + arguments
    let output = Pipe(); process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let result = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    } catch { return nil }
}

private func quote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func truncateUTF8(_ text: String, limit: Int) -> String {
    var result = ""
    for character in text {
        let next = result + String(character)
        if next.utf8.count > limit { break }
        result = next
    }
    return result.isEmpty ? "command" : result
}

func autoRun(_ values: [String]) throws {
    var cwd: String?, name: String?, actor: String?, shell: String?
    var wait = false, json = false, forceNew = false, index = 0
    var argv: [String] = []
    while index < values.count {
        let value = values[index]; index += 1
        if value == "--" { argv = Array(values[index...]); break }
        if value == "--wait" { wait = true; continue }
        if value == "--new" { forceNew = true; continue }
        if value == "--json" { json = true; continue }
        if value == "--help" || value == "-h" { print(help); return }
        guard ["--cwd", "--name", "--actor", "--command"].contains(value), index < values.count else {
            throw RuntimeError("Unexpected or incomplete run option: \(value)")
        }
        let next = values[index]; index += 1
        switch value {
        case "--cwd": cwd = next
        case "--name": name = next
        case "--actor": actor = next
        case "--command": shell = next
        default: break
        }
    }
    guard !(wait && json) else { throw RuntimeError("--wait and --json cannot be combined; --wait streams output") }
    guard (shell != nil) != !argv.isEmpty else { throw RuntimeError("Provide either --command SHELL_STRING or -- program args...") }
    guard shell?.isEmpty != true, argv.first?.isEmpty != true else { throw RuntimeError("Command must not be empty") }
    let current = FileManager.default.currentDirectoryPath
    let path = URL(fileURLWithPath: cwd ?? current, relativeTo: URL(fileURLWithPath: current, isDirectory: true)).standardizedFileURL.resolvingSymlinksInPath().path
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { throw RuntimeError("Working directory does not exist: \(path)") }
    let root = git(["rev-parse", "--show-toplevel"], cwd: path)
    let project = URL(fileURLWithPath: root ?? path).lastPathComponent
    let branch = git(["symbolic-ref", "--quiet", "--short", "HEAD"], cwd: path) ?? git(["rev-parse", "--short", "HEAD"], cwd: path)
    let environment = ProcessInfo.processInfo.environment
    let inferredActor: String
    if environment["CODEX_THREAD_ID"] != nil { inferredActor = "Codex" }
    else if environment["CLAUDECODE"] != nil { inferredActor = "Claude Code" }
    else { inferredActor = "AI/CLI" }
    let selectedActor = actor.flatMap { $0.isEmpty ? nil : $0 } ?? environment["RUNDOCK_ACTOR"].flatMap { $0.isEmpty ? nil : $0 } ?? inferredActor
    let command = shell ?? argv.map(quote).joined(separator: " ")
    let readable = shell ?? argv.joined(separator: " ")
    let selectedName = name.flatMap { $0.isEmpty ? nil : $0 } ?? truncateUTF8(readable, limit: 128)
    let service = Service(project: project, name: selectedName, command: command, cwd: path, startedBy: selectedActor, branch: branch)
    try ready()
    let response = try client.send(Request("run", service: service, actor: selectedActor, forceNew: forceNew))
    guard let selected = response.services?.first, response.services?.count == 1 else { throw RuntimeError("Daemon did not return the selected service") }
    if !wait || json {
        if !json && response.reused == true { print("Reusing existing service") }
        try emit(response, json: json)
    }
    if wait { exit(try stream(id: selected.id, interactive: false)) }
}

// A login shell remains owned by the daemon, so later clients can attach or
// send input to the same project terminal.
func ensureProjectShell(cwd: String?, actor: String?, name: String? = nil) throws -> Response {
    let current = FileManager.default.currentDirectoryPath
    let path = URL(fileURLWithPath: cwd ?? current, relativeTo: URL(fileURLWithPath: current, isDirectory: true)).standardizedFileURL.resolvingSymlinksInPath().path
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { throw RuntimeError("Working directory does not exist: \(path)") }
    let environment = ProcessInfo.processInfo.environment
    let candidate = environment["SHELL"] ?? ""
    let shell = candidate.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: candidate) ? candidate : "/bin/zsh"
    let project = URL(fileURLWithPath: git(["rev-parse", "--show-toplevel"], cwd: path) ?? path).lastPathComponent
    let branch = git(["symbolic-ref", "--quiet", "--short", "HEAD"], cwd: path) ?? git(["rev-parse", "--short", "HEAD"], cwd: path)
    let selectedActor = actor.flatMap { $0.isEmpty ? nil : $0 } ?? environment["RUNDOCK_ACTOR"].flatMap { $0.isEmpty ? nil : $0 } ?? "AI/CLI"
    let service = Service(project: project, name: name ?? "Terminal", command: "exec \(quote(shell)) -l", cwd: path, startedBy: selectedActor, branch: branch)
    try ready()
    return try client.send(Request("run", service: service, actor: selectedActor))
}

func shellCommand(_ values: [String]) throws {
    var args = Arguments(values: values)
    let cwd = try args.option("--cwd"), actor = try args.option("--actor")
    let json = args.flag("--json"), attach = args.flag("--attach")
    guard !(json && attach) else { throw RuntimeError("--json and --attach cannot be combined") }
    try args.finish()
    let response = try ensureProjectShell(cwd: cwd, actor: actor)
    guard let selected = response.services?.first, response.services?.count == 1 else { throw RuntimeError("Daemon did not return the selected shell") }
    if attach { _ = try stream(id: selected.id, interactive: true) }
    else { if !json && response.reused == true { print("Reusing existing project shell") }; try emit(response, json: json) }
}
