import Foundation
import Darwin
import ProcessesProtocol

public enum RuntimeServer {
    public static func run() throws { try Supervisor().run() }
    // Called only in the freshly spawned helper, before the shell is executed.
    public static func runChildHelper(arguments: [String]) throws {
        guard arguments.count == 2 else { throw Failure(message: "Invalid child helper arguments") }
        guard setsid() >= 0 else { throw Failure(message: "setsid failed") }
        guard ioctl(STDIN_FILENO, TIOCSCTTY, 0) == 0 else { throw Failure(message: "TIOCSCTTY failed") }
        guard chdir(arguments[0]) == 0 else { throw Failure(message: "Cannot change directory") }
        let configured = ProcessInfo.processInfo.environment["SHELL"] ?? getpwuid(getuid()).map { String(cString: $0.pointee.pw_shell) } ?? "/bin/sh"
        let shell = configured.hasPrefix("/") && access(configured, X_OK) == 0 ? configured : "/bin/sh"
        let fallback = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let existing = ProcessInfo.processInfo.environment["PATH"] ?? ""
        setenv("PATH", existing.isEmpty ? fallback : existing + ":" + fallback, 1)
        setenv("TERM", "xterm-256color", 1)
        let args = [shell, "-l", "-c", arguments[1]].map { strdup($0) } + [nil]
        args.withUnsafeBufferPointer { _ = execv(shell, UnsafeMutablePointer(mutating: $0.baseAddress!)) }
        throw Failure(message: "Cannot execute shell")
    }
}

private struct Failure: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class Supervisor: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var services: [Service] = []
    private var aiConnections: [String: AIConnection] = [:]
    private var children: [String: (pid: pid_t, fd: Int32)] = [:]
    private var stopping: Set<String> = []
    private let root = ProcessesPaths.root
    private var stopped = false
    private let maxLog = 8 * 1024 * 1024
    private var logBases: [String: UInt64] = [:]
    private var stateURL: URL { root.appendingPathComponent("services.json") }
    private func logURL(_ id: String) -> URL { root.appendingPathComponent("log-\(id)") }
    // The base offset and log bytes share one atomic file, so compaction remains
    // consistent across a crash. The first eight bytes encode the base in LE.
    private func base(_ id: String) -> UInt64 {
        if let value = logBases[id] { return value }
        guard let f = try? FileHandle(forReadingFrom: logURL(id)) else { return 0 }
        defer { try? f.close() }
        let header = (try? f.read(upToCount: 8)) ?? Data()
        guard header.count == 8 else { return 0 }
        let value = header.enumerated().reduce(UInt64(0)) { $0 | (UInt64($1.element) << ($1.offset * 8)) }
        logBases[id] = value; return value
    }
    private func appendLog(_ id: String, _ data: Data) {
        let url = logURL(id)
        let fd = open(url.path, O_RDWR | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        if lseek(fd, 0, SEEK_END) == 0 { var zero: UInt64 = 0; _ = Darwin.write(fd, &zero, 8) }
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if n < 0 && errno == EINTR { continue }; if n <= 0 { break }; offset += n
            }
        }
        let size = lseek(fd, 0, SEEK_END); close(fd)
        guard size > maxLog + 262_144 + 8, let all = try? Data(contentsOf: url), all.count > maxLog + 8 else { return }
        let removed = all.count - 8 - maxLog, newBase = base(id) + UInt64(removed)
        var header = newBase.littleEndian
        var compacted = withUnsafeBytes(of: &header) { Data($0) }
        compacted.append(all.suffix(maxLog))
        do { try compacted.write(to: url, options: .atomic); _ = chmod(url.path, 0o600); logBases[id] = newBase }
        catch { /* Preserve the runtime if disk storage becomes unavailable. */ }
    }
    private func fail(_ s: String) -> Failure { Failure(message: s) }
    private func sys(_ s: String) -> Failure { fail("\(s): \(String(cString: strerror(errno)))") }
    private func persist() throws {
        let data = try JSONEncoder().encode(services)
        try data.write(to: stateURL, options: .atomic)
        guard chmod(stateURL.path, 0o600) == 0 else { throw sys("chmod state") }
    }
    func run() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard chmod(root.path, 0o700) == 0 else { throw sys("chmod directory") }
        let lockFD = open(root.appendingPathComponent("runtime.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw sys("open lock") }
        defer { close(lockFD) }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { throw fail("Runtime already running") }
        if let data = try? Data(contentsOf: stateURL) { services = try JSONDecoder().decode([Service].self, from: data) }
        for i in services.indices {
            if ["running", "starting", "stopping"].contains(services[i].status) { services[i].status = "interrupted"; services[i].endedAt = Date(); services[i].events.append(ServiceEvent("Runtime interrupted")) }
            services[i].ports = nil
            services[i].pid = nil
        }
        try persist()
        signal(SIGPIPE, SIG_IGN)
        let server = socket(AF_UNIX, SOCK_STREAM, 0)
        guard server >= 0 else { throw sys("socket") }
        defer { close(server); unlink(ProcessesPaths.socket) }
        _ = fcntl(server, F_SETFD, FD_CLOEXEC)
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array(ProcessesPaths.socket.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: addr.sun_path) else { throw fail("Socket path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { bytes in bytes.copyBytes(from: path.map { UInt8(bitPattern: $0) }) }
        unlink(ProcessesPaths.socket)
        let result = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { throw sys("bind") }
        guard chmod(ProcessesPaths.socket, 0o600) == 0, listen(server, 16) == 0 else { throw sys("listen") }
        while !stopped {
            let client = accept(server, nil, nil)
            if client < 0 { if errno == EINTR { continue }; throw sys("accept") }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            var uid: uid_t = 0, gid: gid_t = 0
            if getpeereid(client, &uid, &gid) == 0 && uid == getuid() { handle(client) }
            close(client)
        }
    }
    private func handle(_ fd: Int32) {
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var data = Data(); var byte: UInt8 = 0
        while data.count <= 1_048_576 {
            let n = Darwin.read(fd, &byte, 1)
            if n == 0 { break }; if n < 0 { if errno == EINTR { continue }; break }
            if byte == 10 { break }; data.append(byte)
        }
        let response: Response
        do {
            guard data.count <= 1_048_576 else { throw fail("Request too large") }
            let request = try JSONDecoder().decode(Request.self, from: data)
            lock.lock(); defer { lock.unlock() }
            response = try process(request)
        } catch { response = Response(ok: false, error: error.localizedDescription) }
        if var output = try? JSONEncoder().encode(response) {
            output.append(10)
            output.withUnsafeBytes { bytes in
                var sent = 0
                while sent < bytes.count {
                    let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: sent), bytes.count - sent)
                    if n < 0 && errno == EINTR { continue }; if n <= 0 { break }; sent += n
                }
            }
        }
    }
    private func index(_ req: Request) throws -> Int {
        guard let id = req.id, let i = services.firstIndex(where: { $0.id == id }) else { throw fail("Service not found") }
        return i
    }
    private func process(_ req: Request) throws -> Response {
        if let actor = req.actor, actor.utf8.count > 128 { throw fail("Actor too long") }
        switch req.action {
        case "ping": return Response(daemonPID: getpid(), protocolVersion: 3)
        case "ai-connections":
            let now = Date()
            aiConnections = aiConnections.filter { now.timeIntervalSince($0.value.disconnectedAt ?? $0.value.lastSeen) < 86400 }
            let connections = aiConnections.values.map { value -> AIConnection in
                var snapshot = value
                snapshot.isConnected = value.disconnectedAt == nil && now.timeIntervalSince(value.lastSeen) < 15
                return snapshot
            }.sorted { $0.lastSeen > $1.lastSeen }
            return Response(connections: connections)
        case "ai-connect":
            guard let id = req.id, !id.isEmpty, id.utf8.count <= 64, id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }), let name = req.actor, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw fail("Invalid AI session") }
            let version: String?
            if let data = req.data {
                guard data.count <= 128, let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw fail("Invalid AI client version") }
                version = text.isEmpty ? nil : text
            } else { version = nil }
            guard aiConnections[id] == nil else { throw fail("AI session already exists") }
            if aiConnections.count >= 64 {
                let now = Date()
                if let oldest = aiConnections.values.filter({ $0.disconnectedAt != nil || now.timeIntervalSince($0.lastSeen) >= 15 }).min(by: { $0.lastSeen < $1.lastSeen }) { aiConnections.removeValue(forKey: oldest.sessionID) }
            }
            guard aiConnections.count < 64 else { throw fail("AI session limit reached") }
            let now = Date(); aiConnections[id] = AIConnection(sessionID: id, clientName: name, clientVersion: version, connectedAt: now, lastSeen: now)
            return Response()
        case "ai-heartbeat", "ai-used", "ai-disconnect":
            guard let id = req.id, var connection = aiConnections[id], connection.disconnectedAt == nil else { throw fail("AI session not found") }
            let now = Date()
            if req.action == "ai-disconnect" { connection.disconnectedAt = now; connection.isConnected = false }
            else { connection.lastSeen = now; if req.action == "ai-used" { connection.lastUsedAt = now } }
            aiConnections[id] = connection; return Response()
        case "list": return Response(services: services)
        case "add", "run":
            guard var s = req.service else { throw fail("Service required") }
            try validate(s)
            s.cwd = URL(fileURLWithPath: s.cwd).resolvingSymlinksInPath().standardizedFileURL.path
            let role = ServiceIdentity.reuseKey(command: s.command)
            if req.action == "run", req.forceNew != true {
                func sameDirectory(_ existing: Service) -> Bool {
                    URL(fileURLWithPath: existing.cwd).resolvingSymlinksInPath().standardizedFileURL.path == s.cwd
                }
                func matching(_ service: Service) -> Bool { sameDirectory(service) && (service.command == s.command || (role != nil && ServiceIdentity.reuseKey(command: service.command) == role)) }
                let exactLive = services.firstIndex { matching($0) && $0.command == s.command && children[$0.id] != nil }
                let live = services.firstIndex { matching($0) && children[$0.id] != nil }
                let exact = services.firstIndex { matching($0) && $0.command == s.command }
                let inactive = services.firstIndex(where: matching)
                if let i = exactLive ?? live ?? exact ?? inactive {
                    if children[services[i].id] == nil {
                        services[i].command = s.command; services[i].reuseKey = role
                        try start(i, actor: req.actor)
                    }
                    return Response(services: [services[i]], reused: true)
                }
            }
            guard !services.contains(where: { $0.id == s.id || (req.action == "add" && $0.cwd == s.cwd && $0.name == s.name) }) else { throw fail("Service already exists") }
            if req.action == "run" {
                guard children.count < 32 else { throw fail("Active service limit reached") }
                while services.filter({ $0.automatic == true }).count >= 256 {
                    let candidates = services.indices.filter { services[$0].automatic == true && children[services[$0].id] == nil && ["stopped", "completed", "failed", "interrupted"].contains(services[$0].status) }
                    guard let oldest = candidates.min(by: {
                        (services[$0].endedAt ?? services[$0].startedAt ?? services[$0].events.first?.date ?? .distantPast) < (services[$1].endedAt ?? services[$1].startedAt ?? services[$1].events.first?.date ?? .distantPast)
                    }) else { throw fail("Automatic history limit reached") }
                    try removeService(oldest)
                }
            } else {
                guard services.filter({ $0.automatic != true }).count < 32 else { throw fail("Saved service limit reached") }
            }
            s.automatic = req.action == "run" ? true : nil
            s.reuseKey = req.action == "run" ? role : nil
            s.status = "stopped"; s.startedBy = "User"; s.pid = nil; s.startedAt = nil; s.endedAt = nil; s.exitCode = nil; s.ports = nil; s.events = [ServiceEvent("Added")]
            services.append(s)
            if req.action == "run" {
                try start(services.count - 1, actor: req.actor)
                return Response(services: [services.last!], reused: false)
            }
            try persist(); return Response(services: services)
        case "start": let i = try index(req); try start(i, actor: req.actor); return Response(services: services)
        case "stop": let i = try index(req); try stop(i, actor: req.actor); return Response(services: services)
        case "restart": let i = try index(req); try stop(i, actor: req.actor); try start(i, actor: req.actor); return Response(services: services)
        case "remove":
            let i = try index(req); guard children[services[i].id] == nil else { throw fail("Stop service before removing") }
            try removeService(i); return Response(services: services)
        case "read":
            let i = try index(req); let url = logURL(services[i].id); let offset = req.offset ?? 0
            let logBase = base(services[i].id)
            guard let f = try? FileHandle(forReadingFrom: url) else { return Response(data: Data(), offset: logBase) }
            defer { try? f.close() }; let fileSize = (try? f.seekToEnd()) ?? 0; let size = fileSize >= 8 ? fileSize - 8 : 0; let position = min(max(offset, logBase), logBase + size)
            try f.seek(toOffset: position - logBase + 8); let bytes = try f.read(upToCount: 65536) ?? Data(); return Response(data: bytes, offset: position + UInt64(bytes.count))
        case "input":
            let i = try index(req); guard let child = children[services[i].id], let bytes = req.data else { throw fail("Service is not running or input is missing") }
            guard bytes.count <= 65536 else { throw fail("Input exceeds 64 KiB") }
            try bytes.withUnsafeBytes { b in
                var sent = 0; while sent < b.count { let n = Darwin.write(child.fd, b.baseAddress!.advanced(by: sent), b.count - sent); if n < 0 && errno == EINTR { continue }; guard n > 0 else { if errno == EAGAIN || errno == EWOULDBLOCK { throw fail("PTY input busy after \(sent) bytes") }; throw sys("input") }; sent += n }
            }; return Response(services: services)
        case "resize":
            let i = try index(req); guard let child = children[services[i].id], let columns = req.columns, let rows = req.rows, columns > 0, rows > 0 else { throw fail("Running service and valid dimensions required") }
            var ws = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0); guard ioctl(child.fd, TIOCSWINSZ, &ws) == 0 else { throw sys("resize") }; return Response()
        case "event":
            let i = try index(req); guard let bytes = req.data, let message = String(data: bytes, encoding: .utf8), !message.isEmpty, bytes.count <= 256 else { throw fail("UTF-8 event required") }
            event(i, "\(req.actor ?? "User"): \(message)"); try persist(); return Response(services: services)
        case "shutdown": guard children.isEmpty else { throw fail("Stop running services before shutdown") }; stopped = true; return Response()
        default: throw fail("Unknown action")
        }
    }
    private func removeService(_ i: Int) throws {
        let removed = services.remove(at: i)
        do { try persist() } catch { services.insert(removed, at: i); throw error }
        try? FileManager.default.removeItem(at: logURL(removed.id)); logBases.removeValue(forKey: removed.id)
    }
    private func validate(_ s: Service) throws {
        let trimmed = { (v: String) in v.trimmingCharacters(in: .whitespacesAndNewlines) }
        var directory: ObjCBool = false
        guard !trimmed(s.project).isEmpty, !trimmed(s.name).isEmpty, !trimmed(s.command).isEmpty else { throw fail("Project, name and command are required") }
        guard s.project.utf8.count <= 128, s.name.utf8.count <= 128, s.command.utf8.count <= 1024, s.cwd.utf8.count <= 1024, (s.branch?.utf8.count ?? 0) <= 128 else { throw fail("Service limit or field length exceeded") }
        guard s.cwd.hasPrefix("/"), FileManager.default.fileExists(atPath: s.cwd, isDirectory: &directory), directory.boolValue else { throw fail("Working directory must be an existing absolute directory") }
        guard s.port == nil || (1...65535).contains(s.port!) else { throw fail("Invalid port") }
        guard !s.id.isEmpty, s.id.utf8.count <= 64, s.id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { throw fail("Invalid service ID") }
    }
    private func event(_ i: Int, _ message: String) { services[i].events.append(ServiceEvent(String(message.prefix(256)))); if services[i].events.count > 16 { services[i].events.removeFirst(services[i].events.count - 16) } }
    private func start(_ i: Int, actor: String?) throws {
        let s = services[i]; guard children[s.id] == nil else { throw fail("Service already running") }
        guard children.count < 32 else { throw fail("Active service limit reached") }
        var master: Int32 = -1, slave: Int32 = -1
        var initialSize = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &initialSize) == 0 else { throw sys("openpty") }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        var actions: posix_spawn_file_actions_t?; posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions); close(slave) }
        for fd: Int32 in 0...2 { posix_spawn_file_actions_adddup2(&actions, slave, fd) }
        posix_spawn_file_actions_addclose(&actions, master); if slave > 2 { posix_spawn_file_actions_addclose(&actions, slave) }
        var executableSize: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &executableSize)
        var executableBuffer = [CChar](repeating: 0, count: Int(executableSize))
        guard _NSGetExecutablePath(&executableBuffer, &executableSize) == 0 else { close(master); throw fail("Cannot find executable") }
        let executable = String(cString: executableBuffer)
        let args = [executable, "_exec", s.cwd, s.command].map { strdup($0) } + [nil]
        defer { for a in args { free(a) } }
        var pid: pid_t = 0
        let rc = args.withUnsafeBufferPointer { posix_spawn(&pid, executable, &actions, nil, UnsafeMutablePointer(mutating: $0.baseAddress!), environ) }
        guard rc == 0 else { close(master); throw fail("spawn: \(String(cString: strerror(rc)))") }
        appendLog(s.id, Data("\r\n--- Started \(Date()) ---\r\n".utf8))
        children[s.id] = (pid, master); services[i].status = "running"; services[i].pid = pid; services[i].startedAt = Date(); services[i].endedAt = nil; services[i].ports = nil; services[i].exitCode = nil; services[i].startedBy = actor ?? "User"; event(i, "Started by \(services[i].startedBy)")
        let id = s.id
        DispatchQueue.global(qos: .utility).async { [self] in collect(id: id, fd: master) }
        DispatchQueue.global(qos: .utility).async { [self] in monitor(id: id, pid: pid) }
        DispatchQueue.global(qos: .utility).async { [self] in collectPorts(id: id, pid: pid) }
        try persist()
    }
    private func collect(id: String, fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 8192)
        defer { close(fd) }
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n < 0 && errno == EINTR { continue }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                _ = poll(&descriptor, 1, 1000)
                continue
            }
            if n <= 0 { break }
            lock.lock(); appendLog(id, Data(buffer.prefix(n))); lock.unlock()
        }
    }
    // lsof is constrained to the process group created for this service. It runs
    // asynchronously and returns only listening TCP port numbers to clients.
    private func collectPorts(id: String, pid: pid_t) {
        while true {
            lock.lock(); let active = children[id]?.pid == pid; lock.unlock()
            guard active else { return }
            let task = Process(); task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
            task.arguments = ["-nP", "-a", "-g", String(pid), "-iTCP", "-sTCP:LISTEN", "-F", "n"]
            let output = Pipe(); task.standardOutput = output; task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                let bytes = output.fileHandleForReading.readDataToEndOfFile()
                task.waitUntilExit()
                let ports = Set(String(decoding: bytes, as: UTF8.self).split(separator: "\n").compactMap { line -> Int? in
                    guard line.first == "n", let colon = line.lastIndex(of: ":"), let port = Int(line[line.index(after: colon)...]), (1...65535).contains(port) else { return nil }
                    return port
                }).sorted()
                lock.lock()
                if children[id]?.pid == pid, let i = services.firstIndex(where: { $0.id == id }) { services[i].ports = ports }
                lock.unlock()
            } catch { /* Port discovery is best effort. */ }
            Thread.sleep(forTimeInterval: 1)
        }
    }
    private func monitor(id: String, pid: pid_t) {
        while true {
            lock.lock()
            guard children[id]?.pid == pid else { lock.unlock(); return }
            if stopping.contains(id) { lock.unlock(); usleep(100_000); continue }
            var info = siginfo_t(); let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
            if result == 0 && info.si_pid == pid {
                // Keep the leader unreaped until all remaining group members are killed.
                _ = kill(-pid, SIGKILL)
                var status: Int32 = 0; _ = waitpid(pid, &status, 0)
                finish(id: id, status: status, stopped: false); lock.unlock(); return
            }
            if result < 0 && errno != EINTR {
                // If waitid is unavailable, reap only our exact child; do not
                // signal a potentially reused process group after reaping it.
                var status: Int32 = 0
                let reaped = waitpid(pid, &status, WNOHANG)
                if reaped == pid { finish(id: id, status: status, stopped: false); lock.unlock(); return }
                if reaped < 0 && errno == ECHILD {
                    children.removeValue(forKey: id)
                    if let i = services.firstIndex(where: { $0.id == id }) {
                        services[i].pid = nil; services[i].ports = nil; services[i].endedAt = Date(); services[i].status = "interrupted"
                        event(i, "Child exit status unavailable"); try? persist()
                    }
                    lock.unlock(); return
                }
            }
            lock.unlock(); usleep(100_000)
        }
    }
    private func finish(id: String, status: Int32, stopped: Bool) {
        guard let child = children.removeValue(forKey: id), let i = services.firstIndex(where: { $0.id == id }) else { return }
        _ = child; services[i].pid = nil; services[i].ports = nil; services[i].endedAt = Date()
        let signalNumber = status & 0x7f
        services[i].exitCode = signalNumber == 0 ? (status >> 8) & 0xff : 128 + signalNumber
        services[i].status = stopped ? "stopped" : (services[i].exitCode == 0 ? "completed" : "failed")
        event(i, "Exited with code \(services[i].exitCode!)"); try? persist()
    }
    private func stop(_ i: Int, actor: String?) throws {
        let id = services[i].id; guard let child = children[id] else { return }
        stopping.insert(id); defer { stopping.remove(id) }
        for (sig, iterations) in [(SIGINT, 20), (SIGTERM, 20), (SIGKILL, 20)] {
            // The unreaped child pins its process-group ID until waitpid succeeds.
            if kill(-child.pid, sig) != 0 && errno != ESRCH {
                let signalError = errno
                if signalError == EPERM {
                    // An exiting session leader can have no signalable group on
                    // macOS. Only accept that result if our exact child is reaped.
                    for _ in 0..<20 {
                        var status: Int32 = 0
                        let reaped = waitpid(child.pid, &status, WNOHANG)
                        if reaped == child.pid {
                            finish(id: id, status: status, stopped: true); event(i, "Stopped by \(actor ?? "User")"); try persist(); return
                        }
                        if reaped < 0 && errno != EINTR { throw sys("waitpid") }
                        lock.unlock(); usleep(100_000); lock.lock()
                    }
                }
                errno = signalError; throw sys("signal process group")
            }
            for _ in 0..<iterations {
                var info = siginfo_t(); let result = waitid(P_PID, id_t(child.pid), &info, WEXITED | WNOHANG | WNOWAIT)
                if result == 0 && info.si_pid == child.pid {
                    _ = kill(-child.pid, SIGKILL)
                    var status: Int32 = 0; _ = waitpid(child.pid, &status, 0)
                    finish(id: id, status: status, stopped: true); event(i, "Stopped by \(actor ?? "User")"); try persist(); return
                }
                // macOS can leave waitid(WNOWAIT) reporting no status for an
                // interactive job even after SIGKILL. The whole pinned group
                // has already received SIGKILL, so reaping directly is safe;
                // never signal that numeric group again after reaping.
                if sig == SIGKILL {
                    var status: Int32 = 0
                    let reaped = waitpid(child.pid, &status, WNOHANG)
                    if reaped == child.pid {
                        finish(id: id, status: status, stopped: true); event(i, "Stopped by \(actor ?? "User")"); try persist(); return
                    }
                    if reaped < 0 && errno != EINTR { throw sys("waitpid") }
                }
                if result < 0 && errno != EINTR { throw sys("waitid") }
                // Let the PTY collector drain output while the child exits.
                lock.unlock(); usleep(100_000); lock.lock()
            }
        }
        throw fail("Service did not exit after SIGKILL")
    }
}
