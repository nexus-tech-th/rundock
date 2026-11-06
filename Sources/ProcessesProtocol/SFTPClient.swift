import Foundation
import Darwin

public struct SFTPEntry: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let size: UInt64?
    public let isDirectory: Bool
}

/// One bounded OpenSSH SFTP session per operation. No remote shell is involved.
public struct SFTPClient: Sendable {
    public let host: SSHHost
    private let executable: URL
    private let testArguments: [String]?
    public init(host: SSHHost) { self.host = host; self.executable = URL(fileURLWithPath: "/usr/bin/ssh"); self.testArguments = nil }
    init(host: SSHHost, testExecutable: URL, arguments: [String]) { self.host = host; self.executable = testExecutable; self.testArguments = arguments }
    public func list(path: String) async throws -> [SFTPEntry] {
        try await operation { session in try session.list(path) }
    }
    public func download(remotePath: String, localURL: URL) async throws {
        try await operation { session in try session.download(remotePath, localURL) }
    }
    public func upload(localURL: URL, remotePath: String) async throws {
        try await operation { session in try session.upload(localURL, remotePath) }
    }
    private func operation<T: Sendable>(_ body: @escaping @Sendable (SFTPSession) throws -> T) async throws -> T {
        let host = host, executable = executable, testArguments = testArguments
        return try await Task.detached(priority: .utility) {
            try host.validate()
            let session = try SFTPSession(host: host, executable: executable, testArguments: testArguments)
            defer { session.close() }
            return try body(session)
        }.value
    }
}

private struct PacketReader {
    let data: Data
    var offset = 0
    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, offset <= data.count, count <= data.count - offset else { throw SSHWorkspaceError.protocolError("Malformed SFTP packet") }
        defer { offset += count }; return data.subdata(in: offset..<(offset + count))
    }
    mutating func byte() throws -> UInt8 { try bytes(1)[0] }
    mutating func u32() throws -> UInt32 { try bytes(4).reduce(0) { ($0 << 8) | UInt32($1) } }
    mutating func u64() throws -> UInt64 { try bytes(8).reduce(0) { ($0 << 8) | UInt64($1) } }
    mutating func stringData() throws -> Data { try bytes(Int(u32())) }
    mutating func string() throws -> String {
        guard let value = String(data: try stringData(), encoding: .utf8) else { throw SSHWorkspaceError.protocolError("Invalid SFTP filename encoding") }; return value
    }
}
private extension Data {
    mutating func add32(_ value: UInt32) { append(contentsOf: [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]) }
    mutating func add64(_ value: UInt64) { add32(UInt32(truncatingIfNeeded: value >> 32)); add32(UInt32(truncatingIfNeeded: value)) }
    mutating func addString(_ value: Data) { add32(UInt32(value.count)); append(value) }
    mutating func addString(_ value: String) { addString(Data(value.utf8)) }
}

private final class SFTPDeadline: @unchecked Sendable {
    private let lock = NSLock()
    private var expired = false
    func markExpired() { lock.lock(); expired = true; lock.unlock() }
    var isExpired: Bool { lock.lock(); defer { lock.unlock() }; return expired }
}

private func stopOwnedProcess(_ process: Process) {
    guard process.isRunning else { return }
    _ = Darwin.kill(process.processIdentifier, SIGTERM)
    let deadline = Date().addingTimeInterval(2)
    while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
}

private final class SFTPSession: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var nextID: UInt32 = 1
    private let timeout: DispatchWorkItem
    private let deadlineState = SFTPDeadline()
    private var supportsAtomicRename = false
    init(host: SSHHost, executable: URL, testArguments: [String]?) throws {
        process.executableURL = executable
        var args = ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=15", "-p", String(host.port)]
        if let key = host.keyPath, !key.isEmpty { args += ["-i", key] }
        args += ["-l", host.user, "-s", host.host, "sftp"]
        process.arguments = testArguments ?? args; process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let task = process
        let deadlineState = self.deadlineState
        timeout = DispatchWorkItem { deadlineState.markExpired(); stopOwnedProcess(task) }
        try process.run()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120, execute: timeout)
        do {
            var hello = Data([1]); hello.add32(3); try send(hello)
            var version = PacketReader(data: try receive())
            guard try version.byte() == 2, try version.u32() == 3 else { throw SSHWorkspaceError.protocolError("Unsupported SFTP version") }
            while version.offset < version.data.count {
                let name = try version.string(); let value = try version.string()
                if name == "posix-rename@openssh.com" && value == "1" { supportsAtomicRename = true }
            }
        } catch { close(); throw error }
    }
    func close() {
        timeout.cancel(); try? input.fileHandleForWriting.close(); stopOwnedProcess(process); try? output.fileHandleForReading.close()
    }
    private func readExactly(_ count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            let part = try output.fileHandleForReading.read(upToCount: count - data.count) ?? Data()
            guard !part.isEmpty else { throw SSHWorkspaceError.remote(deadlineState.isExpired ? "SFTP operation timed out after 120 seconds" : "SFTP connection closed; check SSH authentication and host key") }
            data.append(part)
        }
        return data
    }
    private func send(_ payload: Data) throws {
        var packet = Data(); packet.add32(UInt32(payload.count)); packet.append(payload); try input.fileHandleForWriting.write(contentsOf: packet)
    }
    private func receive() throws -> Data {
        var header = PacketReader(data: try readExactly(4)); let length = try header.u32()
        guard length > 0, length <= 1_048_576 else { throw SSHWorkspaceError.protocolError("Invalid SFTP packet length") }
        return try readExactly(Int(length))
    }
    private func request(_ type: UInt8, _ body: Data = Data()) throws -> (UInt8, PacketReader) {
        let id = nextID; nextID += 1
        var payload = Data([type]); payload.add32(id); payload.append(body); try send(payload)
        var reply = PacketReader(data: try receive()); let kind = try reply.byte()
        guard try reply.u32() == id else { throw SSHWorkspaceError.protocolError("Mismatched SFTP response") }
        return (kind, reply)
    }
    private func status(_ kind: UInt8, _ reader: inout PacketReader, eof: Bool = false) throws -> Bool {
        guard kind == 101 else { throw SSHWorkspaceError.protocolError("Unexpected SFTP response") }
        let code = try reader.u32(); let message = try reader.string()
        if code == 0 { return true }; if eof && code == 1 { return false }
        throw SSHWorkspaceError.remote("SFTP error \(code): \(String(message.prefix(512)))")
    }
    private func checkedPath(_ path: String) throws {
        guard !path.isEmpty, path.utf8.count <= 16_384, !path.contains("\0") else { throw SSHWorkspaceError.protocolError("Invalid remote path") }
    }
    private func handle(_ type: UInt8, _ path: String, flags: UInt32? = nil) throws -> Data {
        try checkedPath(path); var body = Data(); body.addString(path)
        if let flags { body.add32(flags); body.add32(0) }
        let (kind, initial) = try request(type, body); var reply = initial
        if kind == 101 { _ = try status(kind, &reply); throw SSHWorkspaceError.protocolError("Missing SFTP handle") }
        guard kind == 102 else { throw SSHWorkspaceError.protocolError("Expected SFTP handle") }
        return try reply.stringData()
    }
    private func closeHandle(_ handle: Data) throws { var b = Data(); b.addString(handle); let (kind, r) = try request(4, b); var reply = r; _ = try status(kind, &reply) }
    private func attributes(_ reader: inout PacketReader) throws -> (UInt64?, Bool) {
        let flags = try reader.u32(); let size = flags & 1 != 0 ? try reader.u64() : nil
        if flags & 2 != 0 { _ = try reader.u32(); _ = try reader.u32() }
        let permissions = flags & 4 != 0 ? try reader.u32() : 0
        if flags & 8 != 0 { _ = try reader.u32(); _ = try reader.u32() }
        if flags & 0x80000000 != 0 { let count = try reader.u32(); guard count <= 1024 else { throw SSHWorkspaceError.protocolError("Too many attributes") }; for _ in 0..<count { _ = try reader.stringData(); _ = try reader.stringData() } }
        return (size, (permissions & 0o170000) == 0o040000)
    }
    func list(_ path: String) throws -> [SFTPEntry] {
        let h = try handle(11, path); defer { try? closeHandle(h) }
        var items: [SFTPEntry] = []
        while true {
            var b = Data(); b.addString(h); let (kind, r) = try request(12, b); var reply = r
            if kind == 101 { _ = try status(kind, &reply, eof: true); break }
            guard kind == 104 else { throw SSHWorkspaceError.protocolError("Expected SFTP directory entries") }
            let count = try reply.u32(); guard count <= 10_000, items.count + Int(count) <= 50_000 else { throw SSHWorkspaceError.protocolError("Directory is too large") }
            for _ in 0..<count {
                let name = try reply.string(); _ = try reply.string(); let (size, directory) = try attributes(&reply)
                guard name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { continue }
                items.append(SFTPEntry(name: name, path: path == "/" ? "/" + name : path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "" ? name : path + (path.hasSuffix("/") ? "" : "/") + name, size: size, isDirectory: directory))
            }
        }
        return items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func download(_ remote: String, _ local: URL) throws {
        let h = try handle(3, remote, flags: 1); defer { try? closeHandle(h) }
        guard local.isFileURL else { throw SSHWorkspaceError.protocolError("Local file URL required") }
        let temporary = local.deletingLastPathComponent().appendingPathComponent(".rundock-download-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw SSHWorkspaceError.protocolError("Cannot create local file") }
        let file = try FileHandle(forWritingTo: temporary); defer { try? file.close() }
        var offset: UInt64 = 0
        while true {
            var b = Data(); b.addString(h); b.add64(offset); b.add32(32768)
            let (kind, r) = try request(5, b); var reply = r
            if kind == 101 { _ = try status(kind, &reply, eof: true); break }
            guard kind == 103 else { throw SSHWorkspaceError.protocolError("Expected SFTP data") }
            let data = try reply.stringData(); guard !data.isEmpty, data.count <= 32768 else { throw SSHWorkspaceError.protocolError("Invalid SFTP data") }
            try file.write(contentsOf: data); offset += UInt64(data.count)
        }
        try file.close()
        guard rename(temporary.path, local.path) == 0 else { throw SSHWorkspaceError.protocolError("Cannot save downloaded file") }
    }
    func upload(_ local: URL, _ remote: String) throws {
        guard local.isFileURL else { throw SSHWorkspaceError.protocolError("Local file URL required") }
        try checkedPath(remote)
        let file = try FileHandle(forReadingFrom: local); defer { try? file.close() }
        // Exclusive creation in the destination directory makes the final rename atomic.
        let temporary = remote + ".rundock-upload-" + UUID().uuidString
        let h = try handle(3, temporary, flags: 2 | 8 | 32)
        var isOpen = true, committed = false
        defer {
            if isOpen { try? closeHandle(h) }
            if !committed {
                var body = Data(); body.addString(temporary)
                if let (kind, r) = try? request(13, body) { var reply = r; _ = try? status(kind, &reply) }
            }
        }
        var offset: UInt64 = 0
        while let data = try file.read(upToCount: 32768), !data.isEmpty {
            var b = Data(); b.addString(h); b.add64(offset); b.addString(data)
            let (kind, r) = try request(6, b); var reply = r; _ = try status(kind, &reply); offset += UInt64(data.count)
        }
        try closeHandle(h); isOpen = false
        var body = Data()
        if supportsAtomicRename { body.addString("posix-rename@openssh.com") }
        body.addString(temporary); body.addString(remote)
        let (kind, r) = try request(supportsAtomicRename ? 200 : 18, body); var reply = r
        _ = try status(kind, &reply); committed = true
    }
}
