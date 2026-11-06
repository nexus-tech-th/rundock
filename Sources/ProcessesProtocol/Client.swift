import Foundation
import Darwin

public struct RuntimeError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public final class OutputStreamHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var cancelled = false
    public func cancel() { lock.lock(); cancelled = true; if fd >= 0 { _ = Darwin.shutdown(fd, SHUT_RDWR) }; lock.unlock() }
    fileprivate func attach(_ socket: Int32) -> Bool { lock.lock(); defer { lock.unlock() }; if cancelled { return false }; fd = socket; return true }
    fileprivate func detach() { lock.lock(); fd = -1; lock.unlock() }
    fileprivate var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

public struct RuntimeClient: Sendable {
    public let socketPath: String
    public init(socketPath: String = ProcessesPaths.socket) { self.socketPath = socketPath }

    private func connectSocket(receiveTimeout: Int) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw RuntimeError("Cannot create control socket: \(String(cString: strerror(errno)))") }
        var connected = false
        defer { if !connected { close(fd) } }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: receiveTimeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw RuntimeError("State directory path is too long for a Unix socket. Use a shorter PROCESSES_HOME.") }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { throw RuntimeError("RunDock daemon is unavailable. Run `rundock daemon start`. (\(String(cString: strerror(errno))))") }
        var peerUID: uid_t = 0; var peerGID: gid_t = 0
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == getuid() else { throw RuntimeError("Control socket belongs to a different user") }
        connected = true
        return fd
    }
    public func send(_ request: Request) throws -> Response {
        // Existing bound services are resolved by ID on start/restart, without taskID in the request.
        let longRequest = request.action.hasPrefix("git-") || request.action.hasPrefix("task-") || request.taskID != nil || ["start", "restart"].contains(request.action)
        let fd = try connectSocket(receiveTimeout: longRequest ? 75 : 8)
        defer { close(fd) }
        var payload = try JSONEncoder().encode(request)
        guard payload.count <= 1_000_000 else { throw RuntimeError("Request exceeds 1 MB") }
        payload.append(10)
        try payload.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw RuntimeError("Could not send daemon request") }
                sent += count
            }
        }
        var reply = Data(); var buffer = [UInt8](repeating: 0, count: 16_384)
        while reply.count <= 2_000_000 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw RuntimeError("Daemon closed or timed out before replying") }
            reply.append(contentsOf: buffer.prefix(count))
            if let end = reply.firstIndex(of: 10) {
                let response = try JSONDecoder().decode(Response.self, from: reply.prefix(upTo: end))
                guard response.ok else { throw RuntimeError(response.error ?? "Daemon request failed") }
                return response
            }
        }
        throw RuntimeError("Daemon response exceeds 2 MB")
    }

    @discardableResult
    public func streamOutput(id: String, offset: UInt64 = 0, onEvent: @escaping @Sendable (Result<Response, Error>) -> Void) -> OutputStreamHandle {
        let handle = OutputStreamHandle()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let version = try self.send(Request("ping")).protocolVersion ?? 1
                guard version >= 4 else { throw RuntimeError("RunDock daemon needs upgrading for output streaming. Stop its running services, then restart the daemon.") }
                guard !handle.isCancelled else { return }
                let fd = try self.connectSocket(receiveTimeout: 0)
                defer { handle.detach(); close(fd) }
                guard handle.attach(fd) else { return }
                var request = try JSONEncoder().encode(Request("stream", id: id, offset: offset)); request.append(10)
                try request.withUnsafeBytes { bytes in
                    var sent = 0
                    while sent < bytes.count {
                        let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
                        if n < 0 && errno == EINTR { continue }
                        guard n > 0 else { throw RuntimeError("Could not start output stream") }; sent += n
                    }
                }
                var pending = Data(); var buffer = [UInt8](repeating: 0, count: 16384)
                while !handle.isCancelled {
                    let n = Darwin.read(fd, &buffer, buffer.count)
                    if n < 0 && errno == EINTR { continue }
                    guard n > 0 else { throw RuntimeError("Output stream disconnected") }
                    pending.append(contentsOf: buffer.prefix(n))
                    while let end = pending.firstIndex(of: 10) {
                        let response = try JSONDecoder().decode(Response.self, from: pending.prefix(upTo: end))
                        pending.removeSubrange(...end)
                        guard response.ok else { throw RuntimeError(response.error ?? "Output stream failed") }
                        guard !handle.isCancelled else { return }
                        onEvent(.success(response))
                        if (response.data ?? Data()).isEmpty { return }
                    }
                    guard pending.count <= 2_000_000 else { throw RuntimeError("Output stream response exceeds 2 MB") }
                }
            } catch { if !handle.isCancelled { onEvent(.failure(error)) } }
        }
        return handle
    }

    public func ensureDaemon(executableURL: URL) throws {
        if let existing = try? send(Request("ping")) {
            if (existing.protocolVersion ?? 1) >= 5 { return }
            let services = try send(Request("list")).services ?? []
            guard !services.contains(where: { ["running", "starting", "stopping"].contains($0.status) }) else {
                throw RuntimeError("An older RunDock daemon still owns running services. Stop those services before restarting the daemon to enable output streaming.")
            }
            _ = try send(Request("shutdown"))
            for _ in 0..<40 {
                if !FileManager.default.fileExists(atPath: socketPath) { break }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else { throw RuntimeError("CLI helper not found at \(executableURL.path)") }
        try FileManager.default.createDirectory(at: ProcessesPaths.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let logURL = ProcessesPaths.root.appendingPathComponent("daemon.log")
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) }
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        try log.seekToEnd()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["daemon", "run"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        try process.run()
        for _ in 0..<80 {
            if let response = try? send(Request("ping")), (response.protocolVersion ?? 1) >= 5 { return }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw RuntimeError("Daemon did not start; inspect \(logURL.path)")
    }
}
