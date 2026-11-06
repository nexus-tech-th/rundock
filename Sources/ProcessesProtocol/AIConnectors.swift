import Foundation
import Darwin
import Dispatch

public struct AIConnector: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let kind: String
    public let documentationURL: String
    public let configPath: String?

    public init(id: String, title: String, kind: String, documentationURL: String, configPath: String? = nil) {
        self.id = id
        self.title = title
        self.kind = kind
        self.documentationURL = documentationURL
        self.configPath = configPath
    }
}

public enum AIConnectors {
    private struct CLIResult {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }
    public static let clients: [AIConnector] = [
        .init(id: "codex", title: "Codex", kind: "skill-and-manual-mcp", documentationURL: "https://learn.chatgpt.com/docs/extend/mcp?surface=cli", configPath: ".codex/config.toml"),
        .init(id: "claude-desktop", title: "Claude Desktop", kind: "json", documentationURL: "https://modelcontextprotocol.io/docs/develop/connect-local-servers", configPath: "Library/Application Support/Claude/claude_desktop_config.json"),
        .init(id: "claude-code", title: "Claude Code", kind: "manual-cli", documentationURL: "https://code.claude.com/docs/en/mcp", configPath: nil),
        .init(id: "cursor", title: "Cursor", kind: "json", documentationURL: "https://docs.cursor.com/context/model-context-protocol", configPath: ".cursor/mcp.json"),
        .init(id: "vscode", title: "Visual Studio Code", kind: "json-vscode", documentationURL: "https://code.visualstudio.com/docs/agent-customization/mcp-servers", configPath: "Library/Application Support/Code/User/mcp.json"),
        .init(id: "gemini-cli", title: "Gemini CLI", kind: "json", documentationURL: "https://geminicli.com/docs/tools/mcp-server/", configPath: ".gemini/settings.json"),
        .init(id: "windsurf", title: "Windsurf", kind: "manual-json", documentationURL: "https://docs.windsurf.com/", configPath: nil),
        .init(id: "opencode", title: "OpenCode v1", kind: "manual-versioned", documentationURL: "https://thdxr.dev.opencode.ai/docs/mcp-servers/", configPath: nil),
        .init(id: "opencode-v2", title: "OpenCode v2", kind: "manual-versioned", documentationURL: "https://dev.opencode.ai/v2/docs/migrate-v1/", configPath: nil),
        .init(id: "chatgpt-desktop", title: "ChatGPT desktop", kind: "manual-stdio", documentationURL: "https://learn.chatgpt.com/docs/extend/mcp?surface=app", configPath: nil),
        .init(id: "chatgpt", title: "ChatGPT web", kind: "manual-remote", documentationURL: "https://help.openai.com/en/articles/12584461-developer-mode-and-full-mcp-connectors-in-chatgpt", configPath: nil),
        .init(id: "generic-mcp", title: "Generic MCP client", kind: "snippet", documentationURL: "https://modelcontextprotocol.io/docs/develop/connect-local-servers", configPath: nil)
    ]

    private static let serverName = "rundock"

    /// Locates a supported client CLI without invoking a shell.
    public static func cliExecutable(for client: AIConnector) -> URL? {
        let name: String
        switch client.id {
        case "codex": name = "codex"
        case "claude-code": name = "claude"
        default: return nil
        }
        var candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true).appendingPathComponent(name) }
        candidates += ["/opt/homebrew/bin", "/usr/local/bin"]
            .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(name) }
        candidates.append(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true).appendingPathComponent(name))
        if client.id == "codex" {
            for directory in [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")] {
                candidates.append(directory.appendingPathComponent("Codex.app/Contents/Resources/codex-cli/bin/codex"))
            }
        }
        var seen = Set<String>()
        return candidates.first { candidate in
            seen.insert(candidate.path).inserted && FileManager.default.isExecutableFile(atPath: candidate.path)
        }
    }

    /// Configures the selected CLI client only when explicitly called by the app's user action.
    /// The client process is invoked directly with argv, never through a shell, and is bounded to 10 seconds.
    public static func installCLI(for client: AIConnector, executableURL: URL, clientExecutable: URL? = nil) throws {
        guard client.id == "codex" || client.id == "claude-code" else {
            throw RuntimeError("\(client.title) does not have a supported RunDock CLI setup flow")
        }
        guard executableURL.path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw RuntimeError("RunDock helper must be an existing executable at an absolute path")
        }
        guard let clientExecutable = clientExecutable ?? cliExecutable(for: client),
              clientExecutable.path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: clientExecutable.path) else {
            throw RuntimeError("\(client.title) CLI was not found. Install it and ensure it is available on PATH.")
        }

        if client.id == "codex" {
            let check = try runCLI(clientExecutable, arguments: ["mcp", "get", serverName, "--json"])
            if check.status == 0 {
                guard let object = (try? JSONSerialization.jsonObject(with: check.stdout)) as? [String: Any],
                      object["name"] as? String == serverName,
                      let transport = object["transport"] as? [String: Any],
                      transport["type"] as? String == "stdio",
                      let command = transport["command"] as? String,
                      let arguments = transport["args"] as? [String] else {
                    throw RuntimeError("Codex reports an existing RunDock MCP entry that could not be safely inspected. Review it manually; it was not changed.")
                }
                guard command == executableURL.path, arguments == ["mcp"] else {
                    throw RuntimeError("A different RunDock MCP entry already exists in Codex. Review it manually; it was not changed.")
                }
                return
            }
            guard isMissingServerDiagnostic(check.stderr + check.stdout, clientID: client.id) else {
                throw RuntimeError("Codex could not verify whether a RunDock MCP entry exists (exit \(check.status)). No configuration was changed.")
            }
            let add = try runCLI(clientExecutable, arguments: ["mcp", "add", serverName, "--", executableURL.path, "mcp"])
            guard add.status == 0 else { throw RuntimeError("Codex could not add the RunDock MCP server (exit \(add.status)). No output was recorded.") }
            return
        }

        let check = try runCLI(clientExecutable, arguments: ["mcp", "get", serverName])
        if check.status == 0 {
            throw RuntimeError("A RunDock MCP entry already exists in Claude Code. Review it manually before changing it; it was not modified.")
        }
        guard isMissingServerDiagnostic(check.stderr + check.stdout, clientID: client.id) else {
            throw RuntimeError("Claude Code could not verify whether a RunDock MCP entry exists (exit \(check.status)). No configuration was changed.")
        }
        let add = try runCLI(clientExecutable, arguments: ["mcp", "add", "--scope", "user", "--transport", "stdio", serverName, "--", executableURL.path, "mcp"])
        guard add.status == 0 else { throw RuntimeError("Claude Code could not add the RunDock MCP server (exit \(add.status)). No output was recorded.") }
    }

    private static func isMissingServerDiagnostic(_ data: Data, clientID: String) -> Bool {
        let diagnostic = String(decoding: data, as: UTF8.self)
        switch clientID {
        case "codex": return diagnostic.contains("No MCP server named 'rundock' found.")
        case "claude-code":
            return diagnostic.contains("No MCP server found with name: \"rundock\"") ||
                diagnostic.contains("No MCP server found with name: rundock")
        default: return false
        }
    }

    private static func runCLI(_ executable: URL, arguments: [String]) throws -> CLIResult {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = stdout
        process.standardError = stderr
        let stdoutDone = DispatchSemaphore(value: 0)
        let stderrDone = DispatchSemaphore(value: 0)
        let outputLock = NSLock()
        var output = Data()
        var errorOutput = Data()
        DispatchQueue.global(qos: .utility).async {
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            outputLock.lock(); output = data; outputLock.unlock()
            stdoutDone.signal()
        }
        DispatchQueue.global(qos: .utility).async {
            let data = stderr.fileHandleForReading.readDataToEndOfFile()
            outputLock.lock(); errorOutput = data; outputLock.unlock()
            stderrDone.signal()
        }
        do { try process.run() } catch { throw RuntimeError("Could not start \(executable.lastPathComponent) CLI") }
        let deadline = Date().addingTimeInterval(10)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            let terminateDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning && Date() < terminateDeadline { Thread.sleep(forTimeInterval: 0.025) }
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            _ = stdoutDone.wait(timeout: .now() + 1)
            _ = stderrDone.wait(timeout: .now() + 1)
            throw RuntimeError("\(executable.lastPathComponent) CLI timed out after 10 seconds; no output was recorded.")
        }
        process.waitUntilExit()
        _ = stdoutDone.wait(timeout: .now() + 1)
        _ = stderrDone.wait(timeout: .now() + 1)
        outputLock.lock(); let captured = output; outputLock.unlock()
        outputLock.lock(); let capturedError = errorOutput; outputLock.unlock()
        return CLIResult(status: process.terminationStatus, stdout: captured, stderr: capturedError)
    }

    /// Returns a client-shaped configuration fragment for display or copying in the app.
    public static func configuration(for client: AIConnector, executableURL: URL) -> String {
        let executable = executableURL.path
        if client.id == "codex" {
            return "[mcp_servers.rundock]\ncommand = \(tomlString(executable))\nargs = [\"mcp\"]"
        }
        if client.id == "opencode" {
            return jsonSnippet(rootKey: "mcp", entry: ["type": "local", "command": [executable, "mcp"], "enabled": true])
        }
        if client.id == "opencode-v2" {
            let root: [String: Any] = ["mcp": ["servers": [serverName: ["type": "local", "command": [executable, "mcp"], "disabled": false]]]]
            return String(decoding: (try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])) ?? Data(), as: UTF8.self)
        }
        if client.kind == "manual-stdio" { return "Command: \(executable)\nArguments: mcp\nTransport: STDIO" }
        if client.id == "generic-mcp" {
            return jsonSnippet(rootKey: "mcpServers", entry: ["command": executable, "args": ["mcp"]])
        }
        if client.kind == "json-vscode" {
            return jsonSnippet(rootKey: "servers", entry: ["type": "stdio", "command": executable, "args": ["mcp"]])
        }
        if client.kind == "json" || client.kind == "manual-json" {
            return jsonSnippet(rootKey: "mcpServers", entry: ["command": executable, "args": ["mcp"]])
        }
        if client.id == "claude-code" {
            return "claude mcp add --scope user --transport stdio rundock -- \(shellQuote(executable)) mcp"
        }
        return "RunDock MCP is a local stdio server. This client requires a remote MCP endpoint or a client-specific manual setup; local installation is not available. See \(client.documentationURL)"
    }

    /// Merges RunDock's stdio server into a supported JSON config after explicit user action.
    /// Existing unrelated config and servers are preserved. Differing RunDock entries and
    /// malformed/JSONC files are refused without modifying the original file.
    @discardableResult
    public static func install(for client: AIConnector, executableURL: URL, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        guard client.kind == "json" || client.kind == "json-vscode", let configPath = client.configPath else {
            throw RuntimeError("\(client.title) does not support automatic local JSON MCP installation. Use its documented manual setup instead.")
        }
        guard executableURL.path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw RuntimeError("RunDock helper must be an existing executable at an absolute path")
        }
        let relative = configPath.split(separator: "/").map(String.init)
        guard !relative.isEmpty, !relative.contains("."), !relative.contains("..") else {
            throw RuntimeError("Invalid built-in MCP config path")
        }
        let destination = relative.reduce(homeDirectory) { $0.appendingPathComponent($1) }
        try rejectSymlinkComponents(root: homeDirectory, destination: destination)
        let fm = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        var root = [String: Any]()
        if fm.fileExists(atPath: destination.path) {
            var info = stat()
            guard lstat(destination.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFLNK else {
                throw RuntimeError("Refusing symbolic link config target: \(destination.path)")
            }
            let data = try Data(contentsOf: destination)
            do {
                guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw RuntimeError("Config root must be a JSON object")
                }
                root = decoded
            } catch {
                throw RuntimeError("Cannot safely update \(destination.path): it is not valid JSON. Existing content was left unchanged. (\(error.localizedDescription))")
            }
        }

        let rootKey = client.kind == "json-vscode" ? "servers" : "mcpServers"
        let entry: [String: Any] = client.kind == "json-vscode"
            ? ["type": "stdio", "command": executableURL.path, "args": ["mcp"]]
            : ["command": executableURL.path, "args": ["mcp"]]
        var servers: [String: Any]
        if let existing = root[rootKey] {
            guard let object = existing as? [String: Any] else {
                throw RuntimeError("The \(rootKey) value in \(destination.path) is not a JSON object. Existing content was left unchanged.")
            }
            servers = object
        } else {
            servers = [:]
        }
        if let current = servers[serverName] {
            guard let currentObject = current as? [String: Any], NSDictionary(dictionary: currentObject).isEqual(to: entry) else {
                throw RuntimeError("A different RunDock MCP entry already exists in \(destination.path). It was not overwritten.")
            }
            return destination
        }
        servers[serverName] = entry
        root[rootKey] = servers
        let output: Data
        do {
            output = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw RuntimeError("Cannot encode updated MCP config: \(error.localizedDescription)")
        }

        var targetInfo = stat()
        if lstat(destination.path, &targetInfo) == 0 {
            let backup = destination.appendingPathExtension("rundock-backup-\(UUID().uuidString)")
            try fm.copyItem(at: destination, to: backup)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        }
        let temporary = parent.appendingPathComponent(".\(destination.lastPathComponent).rundock-\(UUID().uuidString)")
        try output.write(to: temporary, options: [])
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        guard rename(temporary.path, destination.path) == 0 else {
            let message = String(cString: strerror(errno))
            try? fm.removeItem(at: temporary)
            throw RuntimeError("Cannot atomically update MCP config \(destination.path): \(message)")
        }
        return destination
    }

    private static func rejectSymlinkComponents(root: URL, destination: URL) throws {
        let rootPath = root.path
        let path = destination.path
        guard path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else {
            throw RuntimeError("MCP config path is outside the configured home directory")
        }
        var current = root
        try rejectSymlink(current)
        for component in String(path.dropFirst(rootPath.count)).split(separator: "/") {
            current.appendPathComponent(String(component))
            try rejectSymlink(current)
        }
    }

    private static func rejectSymlink(_ url: URL) throws {
        var info = stat()
        let result = lstat(url.path, &info)
        if result == 0 {
            if (info.st_mode & S_IFMT) == S_IFLNK {
                throw RuntimeError("MCP config destination contains a symbolic link: \(url.path)")
            }
        } else if errno != ENOENT {
            throw RuntimeError("Cannot inspect MCP config destination \(url.path): \(String(cString: strerror(errno)))")
        }
    }

    private static func jsonSnippet(rootKey: String, entry: [String: Any]) -> String {
        let object = [rootKey: [serverName: entry]]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    private static func tomlString(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
