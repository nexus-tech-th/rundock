import XCTest
import Foundation
@testable import ProcessesProtocol

final class SSHTests: XCTestCase {
    func testValidationAndShellQuoting() throws {
        var host = SSHHost(name: "Local", host: "example.com", user: "alice", keyPath: "/tmp/a key's file")
        let command = try host.terminalCommand()
        XCTAssertTrue(command.contains("'/tmp/a key'\\''s file'"))
        XCTAssertTrue(command.contains("'-l' 'alice' 'example.com'"))
        XCTAssertFalse(command.contains("StrictHostKeyChecking=no"))
        XCTAssertNotNil(try host.keyAgentCommand())
        host.host = "-oProxyCommand=evil"
        XCTAssertThrowsError(try host.terminalCommand())
        host.host = "example.com"; host.user = "a;echo"
        XCTAssertThrowsError(try host.validate())
    }

    func testUnresponsiveProcessIsKilled() async throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { throw XCTSkip("System Python unavailable") }
        let script = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rundock-stubborn-\(UUID().uuidString).py")
        defer { try? FileManager.default.removeItem(at: script) }
        try #"""
import sys, signal, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
sys.stdin.buffer.read(9)
sys.stdout.buffer.write(b'\x00\x00\x00\x05\x02\x00\x00\x00\x04'); sys.stdout.buffer.flush()
while True: time.sleep(1)
"""#.write(to: script, atomically: true, encoding: .utf8)
        let client = SFTPClient(host: SSHHost(name: "test", host: "localhost", user: "test"), testExecutable: python, arguments: [script.path])
        let started = Date()
        do { _ = try await client.list(path: "/"); XCTFail("Unsupported SFTP version must fail") } catch { }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testSystemSFTPServerRoundTrip() async throws {
        let executable = URL(fileURLWithPath: "/usr/libexec/sftp-server")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw XCTSkip("System sftp-server unavailable") }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("ไฟล์ space.txt")
        try Data("contents".utf8).write(to: source)
        let client = SFTPClient(host: SSHHost(name: "test", host: "localhost", user: "test"), testExecutable: executable, arguments: [])
        let entries = try await client.list(path: directory.path)
        XCTAssertTrue(entries.contains { $0.name == source.lastPathComponent })
        let downloaded = directory.appendingPathComponent("download")
        try await client.download(remotePath: source.path, localURL: downloaded)
        XCTAssertEqual(try Data(contentsOf: downloaded), Data("contents".utf8))
        let uploaded = directory.appendingPathComponent("upload")
        try Data("old".utf8).write(to: uploaded)
        try await client.upload(localURL: downloaded, remotePath: uploaded.path)
        XCTAssertEqual(try Data(contentsOf: uploaded), Data("contents".utf8))
        let denyingClient = SFTPClient(host: SSHHost(name: "test", host: "localhost", user: "test"), testExecutable: executable, arguments: ["-P", "write"])
        do {
            try await denyingClient.upload(localURL: downloaded, remotePath: uploaded.path)
            XCTFail("A denied write must fail")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: uploaded), Data("contents".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: directory.path).contains { $0.contains(".rundock-upload-") })
        do {
            try await client.download(remotePath: directory.appendingPathComponent("missing").path, localURL: downloaded)
            XCTFail("Missing remote file must fail")
        } catch { }
        XCTAssertEqual(try Data(contentsOf: downloaded), Data("contents".utf8))
    }

    func testSFTPPacketsAndUnicodeNames() async throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else { throw XCTSkip("System Python is unavailable") }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("server.py")
        try #"""
import sys,struct
r=sys.stdin.buffer; w=sys.stdout.buffer
u=lambda n:struct.pack('>I',n)
s=lambda b:u(len(b))+b

def packet(payload):
 w.write(u(len(payload))+payload);w.flush()
def readn(n):
 b=b''
 while len(b)<n:
  p=r.read(n-len(b))
  if not p: sys.exit(0)
  b+=p
 return b
readn(4); init=readn(5); packet(b'\x02'+u(3))
first=True
while True:
 n=struct.unpack('>I',readn(4))[0]; q=readn(n); typ=q[0]; ident=q[1:5]
 if typ==11 or typ==3: packet(b'\x66'+ident+s(b'h'))
 elif typ==12:
  if first:
   first=False; name='ไฟล์ space.txt'.encode();packet(b'\x68'+ident+u(1)+s(name)+s(b'long')+u(5)+struct.pack('>Q',3)+u(0o100644))
  else: packet(b'\x65'+ident+u(1)+s(b'EOF')+s(b''))
 elif typ==5:
  off=struct.unpack('>Q',q[-12:-4])[0]
  packet((b'\x67'+ident+s(b'abc')) if off==0 else (b'\x65'+ident+u(1)+s(b'EOF')+s(b'')))
 elif typ in (4,6,13,18,200): packet(b'\x65'+ident+u(0)+s(b'OK')+s(b''))
 else: packet(b'\x65'+ident+u(8)+s(b'unsupported')+s(b''))
"""#.write(to: script, atomically: true, encoding: .utf8)
        let host = SSHHost(name: "test", host: "localhost", user: "test")
        let client = SFTPClient(host: host, testExecutable: python, arguments: [script.path])
        let entries = try await client.list(path: "/folder with spaces")
        XCTAssertEqual(entries.first?.name, "ไฟล์ space.txt")
        XCTAssertEqual(entries.first?.path, "/folder with spaces/ไฟล์ space.txt")
        XCTAssertEqual(entries.first?.size, 3)
        let downloaded = directory.appendingPathComponent("download")
        try await client.download(remotePath: "/ไฟล์ space.txt", localURL: downloaded)
        XCTAssertEqual(try Data(contentsOf: downloaded), Data("abc".utf8))
        try await client.upload(localURL: downloaded, remotePath: "/ไฟล์ space.txt")
    }
}
