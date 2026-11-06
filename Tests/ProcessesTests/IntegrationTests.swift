import XCTest
import Foundation
import ProcessesProtocol

final class IntegrationTests: XCTestCase {
    private let fileManager = FileManager.default

    private func temporaryDirectory() throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("rundock-ai-integration-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func bundledSkill() throws -> URL {
        let url = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("skills/rundock/SKILL.md")
        XCTAssertTrue(fileManager.fileExists(atPath: url.path), "Run focused tests from the RunDock package root")
        return url
    }

    func testInstallCopiesFullSkillAndIdenticalRetryIsNoOp() throws {
        let scratch = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: scratch) }
        let expected = scratch.appendingPathComponent("expected", isDirectory: true)
        try fileManager.copyItem(at: bundledSkill().deletingLastPathComponent(), to: expected)

        let installed = try AIIntegration.installCodexSkill(from: bundledSkill(), destinationRoot: scratch.appendingPathComponent("codex", isDirectory: true))
        XCTAssertEqual(installed.lastPathComponent, "rundock")
        XCTAssertEqual(try fileManager.subpathsOfDirectory(atPath: installed.path).sorted(),
                       try fileManager.subpathsOfDirectory(atPath: expected.path).sorted())
        XCTAssertEqual(try Data(contentsOf: installed.appendingPathComponent("SKILL.md")),
                       try Data(contentsOf: expected.appendingPathComponent("SKILL.md")))
        XCTAssertEqual(try AIIntegration.installCodexSkill(from: bundledSkill(), destinationRoot: scratch.appendingPathComponent("codex", isDirectory: true)), installed)
    }

    func testConflictingSkillIsRefusedWithoutOverwrite() throws {
        let scratch = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: scratch) }
        let codexRoot = scratch.appendingPathComponent("codex", isDirectory: true)
        let destination = AIIntegration.codexSkillURL(destinationRoot: codexRoot)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let marker = destination.appendingPathComponent("custom.txt")
        try Data("preserve".utf8).write(to: marker)

        XCTAssertThrowsError(try AIIntegration.installCodexSkill(from: bundledSkill(), destinationRoot: codexRoot))
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "preserve")
        XCTAssertFalse(fileManager.fileExists(atPath: destination.appendingPathComponent("SKILL.md").path))
    }

    func testSymbolicLinkDestinationIsRejected() throws {
        let scratch = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: scratch) }
        let codexRoot = scratch.appendingPathComponent("codex", isDirectory: true)
        try fileManager.createDirectory(at: codexRoot.appendingPathComponent("skills", isDirectory: true), withIntermediateDirectories: true)
        let elsewhere = scratch.appendingPathComponent("unrelated", isDirectory: true)
        try fileManager.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: codexRoot.appendingPathComponent("skills/rundock"), withDestinationURL: elsewhere)

        XCTAssertThrowsError(try AIIntegration.installCodexSkill(from: bundledSkill(), destinationRoot: codexRoot))
        XCTAssertTrue(try fileManager.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    func testInvalidSourceCreatesNoDestinationFolders() throws {
        let scratch = try temporaryDirectory()
        defer { try? fileManager.removeItem(at: scratch) }
        let badSource = scratch.appendingPathComponent("bad/skills/rundock", isDirectory: true)
        try fileManager.createDirectory(at: badSource, withIntermediateDirectories: true)
        let codexRoot = scratch.appendingPathComponent("codex", isDirectory: true)

        XCTAssertThrowsError(try AIIntegration.installCodexSkill(from: badSource.appendingPathComponent("SKILL.md"), destinationRoot: codexRoot))
        XCTAssertFalse(fileManager.fileExists(atPath: codexRoot.path))
    }
}
