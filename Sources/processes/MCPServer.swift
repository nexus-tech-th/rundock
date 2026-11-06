import Foundation
import CoreFoundation
import Darwin
import ProcessesProtocol
import ProcessesRuntime

private let version = "2025-11-25"
private let supportedVersions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
private let limit = 1_048_576
private let names = ["rundock_run", "rundock_shell", "rundock_list", "rundock_start", "rundock_stop", "rundock_restart", "rundock_logs", "rundock_input", "rundock_task", "rundock_git"]
private let descriptions = ["Start or reuse a command in RunDock", "Ensure a persistent project terminal; use input and logs to interact", "List RunDock services", "Start a service", "Stop a service", "Restart a service", "Read up to 64 KiB of service output from a byte offset", "Send text to a running service", "Ensure or list persistent Git worktrees bound to stable AI task keys", "Inspect or change Git state only in the selected task worktree"]

private func schema(_ name: String) -> [String: Any] {
    var properties: [String: Any] = [:]; var required: [String] = []
    func add(_ key: String, _ type: String, _ mandatory: Bool = false) {
        properties[key] = ["type": type]; if mandatory { required.append(key) }
    }
    switch name {
    case "rundock_run": add("command", "string", true); add("cwd", "string"); add("taskID", "string"); add("name", "string"); add("actor", "string"); add("forceNew", "boolean")
    case "rundock_shell": add("cwd", "string"); add("taskID", "string"); add("name", "string"); add("actor", "string")
    case "rundock_task":
        add("action", "string", true); properties["action"] = ["type": "string", "enum": ["ensure", "list"]]
        add("repositoryPath", "string"); add("taskKey", "string"); add("name", "string"); add("client", "string")
    case "rundock_git":
        add("action", "string", true); properties["action"] = ["type": "string", "enum": ["status", "diff", "stage", "unstage", "commit", "push"]]
        add("taskID", "string", true); add("staged", "boolean"); add("message", "string")
        properties["paths"] = ["type": "array", "items": ["type": "string", "minLength": 1], "minItems": 1]
    case "rundock_list": break
    case "rundock_logs": add("id", "string", true); add("offset", "integer")
    case "rundock_input": add("id", "string", true); add("text", "string", true)
    default: add("id", "string", true); add("actor", "string")
    }
    var result: [String: Any] = ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
    if ["rundock_run", "rundock_shell"].contains(name) {
        result["anyOf"] = [["required": ["cwd"]], ["required": ["taskID"]]]
    } else if name == "rundock_task" {
        result["oneOf"] = [
            ["properties": ["action": ["const": "ensure"]], "required": ["repositoryPath", "taskKey", "name", "client"]],
            ["properties": ["action": ["const": "list"]], "not": ["anyOf": ["repositoryPath", "taskKey", "name", "client"].map { ["required": [$0]] }]]
        ]
    } else if name == "rundock_git" {
        result["oneOf"] = [
            ["properties": ["action": ["enum": ["status", "push"]]], "not": ["anyOf": ["paths", "staged", "message"].map { ["required": [$0]] }]],
            ["properties": ["action": ["const": "diff"]], "not": ["required": ["message"]]],
            ["properties": ["action": ["enum": ["stage", "unstage"]]], "required": ["paths"], "not": ["anyOf": ["staged", "message"].map { ["required": [$0]] }]],
            ["properties": ["action": ["const": "commit"]], "required": ["message"], "not": ["anyOf": ["paths", "staged"].map { ["required": [$0]] }]]
        ]
    }
    return result
}
private func gitInfo(_ args: [String], _ cwd: String) -> String? {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.arguments = ["-C", cwd] + args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    do { try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); guard p.terminationStatus == 0 else { return nil }; let value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines); return value.isEmpty ? nil : value } catch { return nil }
}
private func serviceJSON(_ response: Response) throws -> String {
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(response.services ?? []), as: UTF8.self)
}
private func responseJSON(_ response: Response) throws -> String {
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(response), as: UTF8.self)
}
private func call(_ name: String, _ args: [String: Any], clientActor: String) throws -> String {
    guard names.contains(name) else { throw RuntimeError("Unknown tool: \(name)") }
    let props = schema(name)["properties"] as! [String: Any]
    guard args.keys.allSatisfy({ props[$0] != nil }) else { throw RuntimeError("Unexpected tool argument") }
    func string(_ key: String, required: Bool = false) throws -> String? {
        guard let value = args[key] else { if required { throw RuntimeError("Missing \(key)") }; return nil }
        guard let value = value as? String, !value.isEmpty else { throw RuntimeError("\(key) must be a nonempty string") }; return value
    }
    func boolean(_ key: String) throws -> Bool? {
        guard let value = args[key] else { return nil }
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw RuntimeError("\(key) must be a boolean") }
        return number.boolValue
    }
    func only(_ allowed: [String]) throws {
        guard args.keys.allSatisfy({ allowed.contains($0) }) else { throw RuntimeError("Unexpected argument for this action") }
    }
    switch name {
    case "rundock_task":
        let action = try string("action", required: true)!
        let request: Request
        switch action {
        case "list": try only(["action"]); request = Request("task-list")
        case "ensure":
            let repository = try string("repositoryPath", required: true)!
            guard repository.hasPrefix("/") else { throw RuntimeError("repositoryPath must be absolute") }
            request = Request("task-ensure", taskKey: try string("taskKey", required: true), repositoryPath: repository, taskName: try string("name", required: true), clientName: try string("client", required: true))
        default: throw RuntimeError("action must be ensure or list")
        }
        try ready(); return try responseJSON(client.send(request))
    case "rundock_git":
        let action = try string("action", required: true)!, taskID = try string("taskID", required: true)!
        guard ["status", "diff", "stage", "unstage", "commit", "push"].contains(action) else { throw RuntimeError("Unknown Git action") }
        var allowed = ["action", "taskID"]
        if action == "diff" { allowed += ["paths", "staged"] }
        if ["stage", "unstage"].contains(action) { allowed.append("paths") }
        if action == "commit" { allowed.append("message") }
        try only(allowed)
        var request = Request("git-\(action)", taskID: taskID)
        if let value = args["paths"] {
            guard let paths = value as? [String], !paths.isEmpty, paths.allSatisfy({ !$0.isEmpty }) else { throw RuntimeError("paths must be a nonempty array of nonempty strings") }
            request.paths = paths
        }
        if ["stage", "unstage"].contains(action), request.paths == nil { throw RuntimeError("\(action) requires paths") }
        if action == "diff" { request.staged = try boolean("staged") }
        if action == "commit" { request.message = try string("message", required: true) }
        try ready(); return try responseJSON(client.send(request))
    case "rundock_run":
        let command = try string("command", required: true)!
        let cwd = try string("cwd"), taskID = try string("taskID")
        guard cwd != nil || taskID != nil else { throw RuntimeError("cwd or taskID is required") }
        if let cwd, !cwd.hasPrefix("/") { throw RuntimeError("cwd must be the active project's absolute directory") }
        let path = try projectCommandPath(cwd: cwd, taskID: taskID)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { throw RuntimeError("Working directory does not exist") }
        let project = URL(fileURLWithPath: gitInfo(["rev-parse", "--show-toplevel"], path) ?? path).lastPathComponent
        let branch = gitInfo(["symbolic-ref", "--quiet", "--short", "HEAD"], path) ?? gitInfo(["rev-parse", "--short", "HEAD"], path)
        let actor = try string("actor") ?? clientActor
        let serviceName = try string("name") ?? String(command.prefix(32))
        let service = Service(project: project, name: serviceName, command: command, cwd: path, startedBy: actor, branch: branch)
        let forceNew = try boolean("forceNew") ?? false
        try ready()
        return try responseJSON(client.send(Request("run", service: service, actor: actor, forceNew: forceNew, taskID: taskID)))
    case "rundock_shell":
        let cwd = try string("cwd"), taskID = try string("taskID")
        guard cwd != nil || taskID != nil else { throw RuntimeError("cwd or taskID is required") }
        if let cwd, !cwd.hasPrefix("/") { throw RuntimeError("cwd must be the active project's absolute directory") }
        return try responseJSON(ensureProjectShell(cwd: cwd, actor: string("actor") ?? clientActor, name: string("name"), taskID: taskID))
    case "rundock_list": try ready(); return try serviceJSON(client.send(Request("list")))
    case "rundock_logs":
        let id = try string("id", required: true)!
        var offset: UInt64 = 0
        if let value = args["offset"] {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue >= 0, number.doubleValue.rounded() == number.doubleValue, number.doubleValue < Double(UInt64.max) else { throw RuntimeError("offset must be a nonnegative integer") }; offset = number.uint64Value
        }
        try ready()
        let response = try client.send(Request("read", id: id, offset: offset))
        let object: [String: Any] = ["text": String(decoding: response.data ?? Data(), as: UTF8.self), "offset": response.offset ?? offset]
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    case "rundock_input":
        let id = try string("id", required: true)!, text = try string("text", required: true)!
        try ready(); return try serviceJSON(client.send(Request("input", id: id, data: Data(text.utf8))))
    default:
        let id = try string("id", required: true)!, actor = try string("actor") ?? clientActor
        let action = String(name.dropFirst("rundock_".count))
        try ready()
        let response = try client.send(Request(action, id: id, actor: actor))
        let filtered = Response(services: (response.services ?? []).filter { $0.id == id })
        return try serviceJSON(filtered)
    }
}

func runMCP() throws {
    var buffer = Data(), oversized = false, initialized = false
    var clientActor = "MCP"
    let sessionID = UUID().uuidString.lowercased()
    var tracked = false
    var heartbeat: DispatchSourceTimer?
    defer {
        heartbeat?.cancel()
        if tracked { _ = try? client.send(Request("ai-disconnect", id: sessionID)) }
    }
    func send(_ value: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]); data.append(10); FileHandle.standardOutput.write(data)
    }
    func error(_ id: Any, _ code: Int, _ message: String) throws { try send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]) }
    func handle(_ line: Data) throws {
        guard let value = try? JSONSerialization.jsonObject(with: line), let message = value as? [String: Any] else { try error(NSNull(), -32700, "Parse error"); return }
        let id = message["id"]
        guard message["jsonrpc"] as? String == "2.0", let method = message["method"] as? String else { try error(id ?? NSNull(), -32600, "Invalid Request"); return }
        guard let id = id else { return }
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            guard let requested = params["protocolVersion"] as? String, !requested.isEmpty else { try error(id, -32602, "Missing protocolVersion"); return }
            guard !initialized else { try error(id, -32600, "Already initialized"); return }
            let info = params["clientInfo"] as? [String: Any] ?? [:]
            if let name = info["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                clientActor = String(name.prefix(32))
            }
            if clientActor != "RunDock setup verifier" {
                do {
                    try ready()
                    let clientVersion = (info["version"] as? String).map { String($0.prefix(32)) }
                    _ = try client.send(Request("ai-connect", id: sessionID, data: clientVersion.map { Data($0.utf8) }, actor: clientActor))
                    tracked = true
                    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
                    timer.schedule(deadline: .now() + 5, repeating: 5)
                    timer.setEventHandler { _ = try? client.send(Request("ai-heartbeat", id: sessionID)) }
                    timer.resume(); heartbeat = timer
                } catch let failure { try error(id, -32603, "Cannot register RunDock connection: \(failure.localizedDescription)"); return }
            }
            initialized = true
            try send(["jsonrpc": "2.0", "id": id, "result": ["protocolVersion": supportedVersions.contains(requested) ? requested : version, "capabilities": ["tools": ["listChanged": false]], "serverInfo": ["name": "RunDock", "version": "0.4.1"], "instructions": "For parallel AI coding tasks, first use rundock_task action ensure with the actual platform task or conversation key and the active repositoryPath. Resume with the same key. Edit files in the returned worktreePath and pass its opaque task id as taskID to rundock_run, rundock_shell and rundock_git. The MCP connection session is not a conversation ID; when no stable platform key is exposed, require a caller-supplied stable key. Respect an existing user-selected worktree. Run project commands through rundock_run so the user can monitor and control them in RunDock. Supply the active project's absolute cwd from your task context. Infer metadata yourself; the user does not need to fill out a service form. Use rundock_list and rundock_logs before launching a development server and reuse the existing job and discovered port. A code edit or new AI turn is not a reason to start a replacement at the next port. Common dev-server commands reuse a live job in the same cwd; forceNew is only for an explicit request for parallel instances. Use rundock_shell to reconnect to the project's persistent interactive PTY, then rundock_input and rundock_logs. Do not send shell commands into a foreground dev server. Keep managed servers and shells available after completing the task unless asked to stop them."]])
        case "ping": try send(["jsonrpc": "2.0", "id": id, "result": [:]])
        case "tools/list":
            guard initialized else { try error(id, -32002, "Not initialized"); return }
            let tools: [[String: Any]] = zip(names, descriptions).map { ["name": $0.0, "description": $0.1, "inputSchema": schema($0.0)] }
            try send(["jsonrpc": "2.0", "id": id, "result": ["tools": tools]])
        case "tools/call":
            guard initialized else { try error(id, -32002, "Not initialized"); return }
            guard let name = params["name"] as? String, params["arguments"] == nil || params["arguments"] is [String: Any] else { try error(id, -32602, "Invalid tool parameters"); return }
            guard names.contains(name) else { try error(id, -32602, "Unknown tool: \(name)"); return }
            var result: [String: Any]
            do {
                let text = try call(name, params["arguments"] as? [String: Any] ?? [:], clientActor: clientActor)
                if tracked { _ = try? client.send(Request("ai-used", id: sessionID)) }
                result = ["content": [["type": "text", "text": text]], "isError": false]
            }
            catch { result = ["content": [["type": "text", "text": error.localizedDescription]], "isError": true] }
            try send(["jsonrpc": "2.0", "id": id, "result": result])
        default: try error(id, -32601, "Method not found")
        }
    }
    var bytes = [UInt8](repeating: 0, count: 8192)
    while true {
        let count = Darwin.read(STDIN_FILENO, &bytes, bytes.count)
        if count < 0 && errno == EINTR { continue }; if count <= 0 { break }
        for byte in bytes.prefix(count) {
            if byte == 10 {
                if oversized { try error(NSNull(), -32600, "Message exceeds 1 MiB") }
                else { try handle(buffer) }
                buffer.removeAll(keepingCapacity: true); oversized = false
            } else if !oversized {
                if buffer.count >= limit { buffer.removeAll(); oversized = true } else { buffer.append(byte) }
            }
        }
    }
}
