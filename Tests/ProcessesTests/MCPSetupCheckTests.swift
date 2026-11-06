import XCTest
import Foundation
import ProcessesProtocol

final class MCPSetupCheckTests: XCTestCase {
    private let fileManager = FileManager.default

    private func helper(body: String) throws -> (URL, URL) {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("rundock-mcp-check-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("rundock-helper")
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (root, executable)
    }

    private func handshakeScript(tools: [String]) -> String {
        let names = tools.map { "{\"name\":\"\($0)\"}" }.joined(separator: ",")
        return "while IFS= read -r line; do\n" +
            "  case \"$line\" in\n" +
            "    *notifications*) : ;;\n" +
            "    *initialize*) printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-11-25\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"RunDock\",\"version\":\"test\"}}}' ;;\n" +
            "    *tools*) printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[\(names)]}}' ;;\n" +
            "  esac\n" +
            "done"
    }

    func testVerifiesInitializedRunDockAndRequiredTools() throws {
        let required = ["rundock_run", "rundock_shell", "rundock_list", "rundock_start", "rundock_stop", "rundock_restart", "rundock_logs", "rundock_input"]
        let (root, helper) = try helper(body: handshakeScript(tools: required))
        defer { try? fileManager.removeItem(at: root) }

        let result = try AIConnectors.verifyMCP(executableURL: helper)
        XCTAssertEqual(result.protocolVersion, "2025-11-25")
        XCTAssertEqual(result.toolNames, required.sorted())
    }

    func testActualRunDockHelper() throws {
        guard let path = ProcessInfo.processInfo.environment["PROCESSES_TEST_EXECUTABLE"] else { throw XCTSkip("Set PROCESSES_TEST_EXECUTABLE for actual helper verification") }
        let result = try AIConnectors.verifyMCP(executableURL: URL(fileURLWithPath: path))
        XCTAssertEqual(result.toolNames.count, 8)
    }

    func testRejectsHelperMissingRequiredTool() throws {
        let tools = ["rundock_run", "rundock_list", "rundock_logs"]
        let (root, helper) = try helper(body: handshakeScript(tools: tools))
        defer { try? fileManager.removeItem(at: root) }

        XCTAssertThrowsError(try AIConnectors.verifyMCP(executableURL: helper))
    }

    func testRejectsNonRunDockHandshake() throws {
        let (root, helper) = try helper(body: "while IFS= read -r line; do case \"$line\" in *initialize*) printf '%s\\n' '{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-11-25\",\"serverInfo\":{\"name\":\"Other\",\"version\":\"1\"}}}' ;; esac; done")
        defer { try? fileManager.removeItem(at: root) }

        XCTAssertThrowsError(try AIConnectors.verifyMCP(executableURL: helper))
    }
}
