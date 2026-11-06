import Foundation
import Darwin

public struct MCPSetupVerification: Sendable, Equatable {
    public let protocolVersion: String
    public let toolNames: [String]
}

public extension AIConnectors {
    /// Starts RunDock's local MCP helper and verifies its initialize/tools-list handshake.
    /// This launches only the supplied helper, performs no client config writes, and never
    /// returns server output beyond the negotiated version and tool names.
    static func verifyMCP(executableURL: URL) throws -> MCPSetupVerification {
        guard executableURL.path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw RuntimeError("RunDock helper is not an executable at the selected path")
        }

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = ["mcp"]
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw RuntimeError("Could not start the RunDock MCP helper") }
        input.fileHandleForReading.closeFile()
        output.fileHandleForWriting.closeFile()
        defer { stop(process) }

        let deadline = Date().addingTimeInterval(10)
        let stdin = input.fileHandleForWriting
        let stdout = output.fileHandleForReading
        let initialize: [String: Any] = [
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": ["protocolVersion": "2025-11-25", "capabilities": [:], "clientInfo": ["name": "RunDock setup verifier", "version": "1"]]
        ]
        let initializeResponse = try exchange(initialize, expectedID: 1, input: stdin, output: stdout, deadline: deadline)
        guard let initializeResult = initializeResponse["result"] as? [String: Any],
              let negotiatedVersion = initializeResult["protocolVersion"] as? String,
              let serverInfo = initializeResult["serverInfo"] as? [String: Any],
              serverInfo["name"] as? String == "RunDock" else {
            throw RuntimeError("RunDock MCP initialization response was invalid")
        }

        try writeLine(["jsonrpc": "2.0", "method": "notifications/initialized"], to: stdin)
        let toolsResponse = try exchange(["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:]], expectedID: 2, input: stdin, output: stdout, deadline: deadline)
        guard let result = toolsResponse["result"] as? [String: Any],
              let tools = result["tools"] as? [[String: Any]] else {
            throw RuntimeError("RunDock MCP tool list response was invalid")
        }
        let toolNames = tools.compactMap { $0["name"] as? String }.sorted()
        let required = ["rundock_run", "rundock_shell", "rundock_list", "rundock_start", "rundock_stop", "rundock_restart", "rundock_logs", "rundock_input", "rundock_task", "rundock_git"]
        let missing = required.filter { !toolNames.contains($0) }
        guard missing.isEmpty else {
            throw RuntimeError("RunDock MCP helper is missing required tools: \(missing.joined(separator: ", "))")
        }
        return MCPSetupVerification(protocolVersion: negotiatedVersion, toolNames: toolNames)
    }
}

private func writeLine(_ value: [String: Any], to input: FileHandle) throws {
    do {
        var data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        data.append(10)
        try input.write(contentsOf: data)
    } catch {
        throw RuntimeError("Could not send MCP setup verification request")
    }
}

private func exchange(_ request: [String: Any], expectedID: Int, input: FileHandle, output: FileHandle, deadline: Date) throws -> [String: Any] {
    try writeLine(request, to: input)
    var line = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    let descriptor = output.fileDescriptor
    while Date() < deadline {
        var ready = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
        let remaining = max(1, Int32(deadline.timeIntervalSinceNow * 1000))
        let state = poll(&ready, 1, remaining)
        if state < 0 && errno == EINTR { continue }
        guard state > 0 else { break }
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw RuntimeError("RunDock MCP helper closed before responding") }
        for byte in buffer.prefix(count) {
            if byte == 10 {
                guard let response = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                      response["jsonrpc"] as? String == "2.0",
                      (response["id"] as? Int) == expectedID,
                      response["error"] == nil else {
                    throw RuntimeError("RunDock MCP helper returned an invalid response")
                }
                return response
            }
            guard line.count < 1_048_576 else { throw RuntimeError("RunDock MCP helper response exceeded 1 MiB") }
            line.append(byte)
        }
    }
    throw RuntimeError("RunDock MCP verification timed out after 10 seconds")
}

private func stop(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    let deadline = Date().addingTimeInterval(0.5)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.025) }
    if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
}
