import XCTest
import Foundation
import ProcessesProtocol

final class ConnectorTests: XCTestCase {
    private let fileManager = FileManager.default
    private let helper = URL(fileURLWithPath: "/bin/echo")

    private func scratchHome() throws -> URL {
        let home = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("rundock-connector-test-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func client(_ id: String) throws -> AIConnector {
        try XCTUnwrap(AIConnectors.clients.first { $0.id == id })
    }

    private func fakeCLI(home: URL, body: String) throws -> (URL, URL) {
        let executable = home.appendingPathComponent("fake-client")
        let trace = home.appendingPathComponent("argv.txt")
        let script = "#!/bin/sh\nTRACE='\(trace.path)'\nprintf '%s\\n' \"$*\" >> \"$TRACE\"\n\(body)\n"
        try Data(script.utf8).write(to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (executable, trace)
    }

    func testMergePreservesExistingConfigAndServers() throws {
        let home = try scratchHome()
        defer { try? fileManager.removeItem(at: home) }
        let target = home.appendingPathComponent(".cursor/mcp.json")
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let initial: [String: Any] = ["theme": "dark", "mcpServers": ["other": ["command": "/usr/bin/true"]]]
        try JSONSerialization.data(withJSONObject: initial).write(to: target)

        let installed = try AIConnectors.install(for: client("cursor"), executableURL: helper, homeDirectory: home)
        XCTAssertEqual(installed, target)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: target)) as? [String: Any])
        XCTAssertEqual(result["theme"] as? String, "dark")
        let servers = try XCTUnwrap(result["mcpServers"] as? [String: Any])
        XCTAssertNotNil(servers["other"])
        let runDock = try XCTUnwrap(servers["rundock"] as? [String: Any])
        XCTAssertEqual(runDock["command"] as? String, helper.path)
        XCTAssertEqual(runDock["args"] as? [String], ["mcp"])
    }

    func testIdenticalRetryDoesNotCreateBackupOrChangeContents() throws {
        let home = try scratchHome()
        defer { try? fileManager.removeItem(at: home) }
        let client = try self.client("gemini-cli")
        let target = try AIConnectors.install(for: client, executableURL: helper, homeDirectory: home)
        let before = try Data(contentsOf: target)
        let retry = try AIConnectors.install(for: client, executableURL: helper, homeDirectory: home)
        XCTAssertEqual(retry, target)
        XCTAssertEqual(try Data(contentsOf: target), before)
        XCTAssertFalse(try fileManager.contentsOfDirectory(atPath: target.deletingLastPathComponent().path).contains { $0.contains("rundock-backup") })
    }

    func testDifferentExistingEntryIsRefusedAndUnchanged() throws {
        let home = try scratchHome()
        defer { try? fileManager.removeItem(at: home) }
        let target = home.appendingPathComponent(".cursor/mcp.json")
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data(#"{"mcpServers":{"rundock":{"command":"/different/helper","args":["mcp"]}}}"#.utf8)
        try original.write(to: target)

        XCTAssertThrowsError(try AIConnectors.install(for: client("cursor"), executableURL: helper, homeDirectory: home))
        XCTAssertEqual(try Data(contentsOf: target), original)
        let backups = try fileManager.contentsOfDirectory(atPath: target.deletingLastPathComponent().path).filter { $0.contains("rundock-backup") }
        XCTAssertTrue(backups.isEmpty)
    }

    func testMalformedJSONIsRefusedWithoutChangingFile() throws {
        let home = try scratchHome()
        defer { try? fileManager.removeItem(at: home) }
        let target = home.appendingPathComponent(".cursor/mcp.json")
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("{ invalid jsonc // comment".utf8)
        try original.write(to: target)

        XCTAssertThrowsError(try AIConnectors.install(for: client("cursor"), executableURL: helper, homeDirectory: home))
        XCTAssertEqual(try Data(contentsOf: target), original)
    }

    func testSymbolicLinkConfigTargetIsRejected() throws {
        let home = try scratchHome()
        defer { try? fileManager.removeItem(at: home) }
        let folder = home.appendingPathComponent(".cursor", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let outside = home.appendingPathComponent("untouched.json")
        let original = Data("{}".utf8)
        try original.write(to: outside)
        try fileManager.createSymbolicLink(at: folder.appendingPathComponent("mcp.json"), withDestinationURL: outside)

        XCTAssertThrowsError(try AIConnectors.install(for: client("cursor"), executableURL: helper, homeDirectory: home))
        XCTAssertEqual(try Data(contentsOf: outside), original)
    }

    func testUnsupportedManualConnectorCannotInstall() throws {
        let home = try scratchHome()
        defer { try? fileManager.removeItem(at: home) }
        XCTAssertThrowsError(try AIConnectors.install(for: client("chatgpt"), executableURL: helper, homeDirectory: home))
        XCTAssertTrue(try fileManager.contentsOfDirectory(atPath: home.path).isEmpty)
    }

    func testCodexCLIUsesExactArgumentBoundariesAndAddsOnlyAfterMissingEntry() throws {
        let home = try scratchHome()
        defer { try? fileManager.removeItem(at: home) }
        let (fake, trace) = try fakeCLI(home: home, body: "case \"$1 $2\" in 'mcp get') echo \"Error: No MCP server named 'rundock' found.\" >&2; exit 1 ;; 'mcp add') exit 0 ;; esac\nexit 9")
        try AIConnectors.installCLI(for: client("codex"), executableURL: helper, clientExecutable: fake)
        let invocations = try String(contentsOf: trace, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(invocations.count, 2)
        XCTAssertEqual(invocations[0], "mcp get rundock --json")
        XCTAssertEqual(invocations[1], "mcp add rundock -- \(helper.path) mcp")
    }

    func testCodexCLILeavesDifferentExistingEntryUntouched() throws {
        let home = try scratchHome()
        defer { try? fileManager.removeItem(at: home) }
        let body = "if [ \"$1 $2\" = 'mcp get' ]; then printf '%s' '{\"name\":\"rundock\",\"transport\":{\"type\":\"stdio\",\"command\":\"/different/helper\",\"args\":[\"mcp\"]}}'; exit 0; fi\nexit 0"
        let (fake, trace) = try fakeCLI(home: home, body: body)
        XCTAssertThrowsError(try AIConnectors.installCLI(for: client("codex"), executableURL: helper, clientExecutable: fake))
        XCTAssertEqual(try String(contentsOf: trace, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "mcp get rundock --json")
    }

    func testCodexNestedStdioTransportExactMatchIsNoOp() throws {
        let home = try scratchHome()
        defer { try? fileManager.removeItem(at: home) }
        let body = "if [ \"$1 $2\" = 'mcp get' ]; then printf '%s' '{\"name\":\"rundock\",\"enabled\":true,\"transport\":{\"type\":\"stdio\",\"command\":\"/bin/echo\",\"args\":[\"mcp\"],\"env\":null}}'; exit 0; fi\nexit 0"
        let (fake, trace) = try fakeCLI(home: home, body: body)
        try AIConnectors.installCLI(for: client("codex"), executableURL: helper, clientExecutable: fake)
        XCTAssertEqual(try String(contentsOf: trace, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "mcp get rundock --json")
    }

    func testClaudeCodeCLIUsesUserScopeAndDoesNotReplaceExistingEntry() throws {
        let home = try scratchHome()
        defer { try? fileManager.removeItem(at: home) }
        let (fake, trace) = try fakeCLI(home: home, body: "case \"$1 $2\" in 'mcp get') echo 'No MCP server found with name: \"rundock\"' >&2; exit 1 ;; 'mcp add') exit 0 ;; esac\nexit 9")
        try AIConnectors.installCLI(for: client("claude-code"), executableURL: helper, clientExecutable: fake)
        let invocations = try String(contentsOf: trace, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(invocations.count, 2)
        XCTAssertEqual(invocations[0], "mcp get rundock")
        XCTAssertEqual(invocations[1], "mcp add --scope user --transport stdio rundock -- \(helper.path) mcp")

        let existingHome = try scratchHome()
        defer { try? fileManager.removeItem(at: existingHome) }
        let (existing, existingTrace) = try fakeCLI(home: existingHome, body: "exit 0")
        XCTAssertThrowsError(try AIConnectors.installCLI(for: client("claude-code"), executableURL: helper, clientExecutable: existing))
        XCTAssertEqual(try String(contentsOf: existingTrace, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "mcp get rundock")
    }

    func testUnexpectedCodexGetFailureDoesNotAttemptAdd() throws {
        let home = try scratchHome()
        defer { try? fileManager.removeItem(at: home) }
        let (fake, trace) = try fakeCLI(home: home, body: "echo 'configuration could not be loaded' >&2\nexit 2")
        XCTAssertThrowsError(try AIConnectors.installCLI(for: client("codex"), executableURL: helper, clientExecutable: fake))
        XCTAssertEqual(try String(contentsOf: trace, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), "mcp get rundock --json")
    }
}
