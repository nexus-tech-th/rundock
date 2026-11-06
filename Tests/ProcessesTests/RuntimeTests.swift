import XCTest
import Foundation
import Darwin
import ProcessesProtocol

final class RuntimeTests: XCTestCase {
    func testOlderServiceStateDecodesWithoutNewFields() throws {
        let original = Service(id: "legacy", project: "P", name: "N", command: "echo ok", cwd: "/tmp")
        let encoded = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "ports"); object.removeValue(forKey: "endedAt")
        let restored = try JSONDecoder().decode(Service.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(restored.automatic)
        XCTAssertNil(restored.ports)
        XCTAssertNil(restored.endedAt)
    }

    // Run with PROCESSES_TEST_EXECUTABLE pointing to the built CLI. Unix socket
    // creation must be allowed by the host sandbox.
    func testSupervisorLifecycle() throws {
        guard let executable = ProcessInfo.processInfo.environment["PROCESSES_TEST_EXECUTABLE"] else {
            throw XCTSkip("Set PROCESSES_TEST_EXECUTABLE to the built processes CLI")
        }
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("pr-\(UUID().uuidString.prefix(8))")
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["daemon", "run"]
        process.environment = ProcessInfo.processInfo.environment.merging(["PROCESSES_HOME": root.path]) { _, new in new }
        try process.run()
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() }; try? FileManager.default.removeItem(at: root) }
        let socketPath = root.appendingPathComponent("control.sock").path
        for _ in 0..<100 { if FileManager.default.fileExists(atPath: socketPath) { break }; usleep(50_000) }
        func request(_ value: Request) throws -> Response {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0); XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
            var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
            let path = Array(socketPath.utf8CString).map { UInt8(bitPattern: $0) }
            guard path.count <= MemoryLayout.size(ofValue: addr.sun_path) else { throw NSError(domain: "path", code: 1) }
            withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path) }
            let connected = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            XCTAssertEqual(connected, 0)
            var data = try JSONEncoder().encode(value); data.append(10)
            let sent = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }; XCTAssertEqual(sent, data.count)
            var reply = Data(); var byte: UInt8 = 0
            while Darwin.read(fd, &byte, 1) == 1 && byte != 10 { reply.append(byte) }
            return try JSONDecoder().decode(Response.self, from: reply)
        }
        var invalid = Service(id: "invalid", project: "P", name: "N", command: "echo ok", cwd: "relative")
        XCTAssertFalse(try request(Request("add", service: invalid)).ok)
        invalid.id = "../escape"; invalid.cwd = "/tmp"
        XCTAssertFalse(try request(Request("add", service: invalid)).ok)
        invalid.id = "invalid"; invalid.port = 65536
        XCTAssertFalse(try request(Request("add", service: invalid)).ok)
        let service = Service(id: "test", project: "P", name: "N", command: "printf 'INITIAL_SIZE:'; stty size; read line; echo GOT:$line; sleep 30", cwd: "/tmp")
        XCTAssertTrue(try request(Request("add", service: service)).ok)
        XCTAssertFalse(try request(Request("add", service: service)).ok)
        XCTAssertTrue(try request(Request("start", id: service.id, actor: "Tester")).ok)
        XCTAssertFalse(try request(Request("start", id: service.id)).ok)
        XCTAssertTrue(try request(Request("input", id: service.id, data: Data("hello\n".utf8))).ok)
        var output = ""
        for _ in 0..<100 {
            let response = try request(Request("read", id: service.id, offset: 0))
            output = String(decoding: response.data ?? Data(), as: UTF8.self)
            if output.contains("GOT:hello") { break }; usleep(50_000)
        }
        XCTAssertTrue(output.contains("GOT:hello"))
        XCTAssertTrue(output.contains("INITIAL_SIZE:24 80"), "PTY starts at 80 × 24 before a resize")
        XCTAssertFalse(try request(Request("shutdown")).ok)
        XCTAssertTrue(try request(Request("restart", id: service.id)).ok)
        let unrelated = Process(); unrelated.executableURL = URL(fileURLWithPath: "/bin/sleep"); unrelated.arguments = ["30"]
        try unrelated.run(); defer { if unrelated.isRunning { unrelated.terminate(); unrelated.waitUntilExit() } }
        XCTAssertTrue(try request(Request("stop", id: service.id)).ok)
        XCTAssertTrue(unrelated.isRunning, "Stopping a service must not signal unrelated processes")
        let control = Service(id: "control", project: "P", name: "Control", command: "trap 'echo INTERRUPTED; exit 0' INT; while :; do sleep 1; done", cwd: "/tmp")
        XCTAssertTrue(try request(Request("add", service: control)).ok)
        XCTAssertTrue(try request(Request("start", id: control.id)).ok)
        usleep(500_000)
        XCTAssertTrue(try request(Request("input", id: control.id, data: Data([3]))).ok)
        var interrupted = false
        for _ in 0..<100 {
            let response = try request(Request("read", id: control.id, offset: 0))
            if String(decoding: response.data ?? Data(), as: UTF8.self).contains("INTERRUPTED") { interrupted = true; break }
            usleep(50_000)
        }
        XCTAssertTrue(interrupted, "Ctrl-C must reach the controlling terminal's foreground group")
        let controlStop = try request(Request("stop", id: control.id))
        XCTAssertTrue(controlStop.ok, controlStop.error ?? "Stop failed without an error")
        // Concurrent automatic requests must share one service and one child.
        let automatic = Service(id: "automatic", project: "Auto", name: "Runner", command: "sleep 30", cwd: "/tmp")
        let resultLock = NSLock()
        var results: [Response] = []
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            if let response = try? request(Request("run", service: automatic, actor: "AI")) {
                resultLock.lock(); results.append(response); resultLock.unlock()
            }
        }
        XCTAssertEqual(results.count, 8)
        XCTAssertTrue(results.allSatisfy { $0.ok && $0.services?.count == 1 })
        XCTAssertEqual(Set(results.compactMap { $0.services?.first?.pid }).count, 1)
        let automaticID = try XCTUnwrap(results.first?.services?.first?.id)
        let snapshot = try request(Request("list"))
        XCTAssertEqual(snapshot.services?.filter { $0.command == automatic.command }.count, 1)
        XCTAssertTrue(try request(Request("stop", id: automaticID)).ok)
        let stopped = try XCTUnwrap(try request(Request("list")).services?.first { $0.id == automaticID })
        XCTAssertEqual(stopped.status, "stopped")
        XCTAssertNotNil(stopped.endedAt)
        for (id, command, expected, code) in [("success", "exit 0", "completed", Int32(0)), ("failure", "exit 7", "failed", Int32(7))] {
            let item = Service(id: id, project: "Auto", name: id, command: command, cwd: "/tmp")
            XCTAssertTrue(try request(Request("run", service: item)).ok)
            var observed: Service?
            for _ in 0..<100 {
                observed = try request(Request("list")).services?.first { $0.id == id }
                if observed?.pid == nil { break }
                usleep(50_000)
            }
            XCTAssertEqual(observed?.status, expected)
            XCTAssertEqual(observed?.exitCode, code)
            XCTAssertNotNil(observed?.endedAt)
        }
        // Completed automatic jobs are history, not active capacity.
        for number in 0..<36 {
            let item = Service(id: "history-\(number)", project: "Auto", name: "History", command: "exit 0 # \(number)", cwd: "/tmp")
            let launched = try request(Request("run", service: item))
            XCTAssertTrue(launched.ok, launched.error ?? "Automatic run failed")
            for _ in 0..<100 {
                let current = try request(Request("list")).services?.first { $0.id == item.id }
                if current?.status == "completed" { break }
                usleep(50_000)
            }
        }
        let history = try XCTUnwrap(try request(Request("list")).services)
        XCTAssertEqual(history.filter { $0.id.hasPrefix("history-") && $0.status == "completed" }.count, 36)
        XCTAssertNotNil(history.first { $0.id == service.id }, "Manual service must survive automatic runs")
        XCTAssertTrue(try request(Request("shutdown")).ok)
        process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
    }
}
