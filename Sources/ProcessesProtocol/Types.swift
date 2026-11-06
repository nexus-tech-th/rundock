import Foundation

public struct Service: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var project: String
    public var name: String
    public var command: String
    public var cwd: String
    public var port: Int?
    public var ports: [Int]?
    public var automatic: Bool?
    public var reuseKey: String?
    public var startedBy: String
    public var branch: String?
    public var status: String
    public var pid: Int32?
    public var startedAt: Date?
    public var endedAt: Date?
    public var exitCode: Int32?
    public var events: [ServiceEvent]
    public init(id: String = UUID().uuidString.lowercased(), project: String, name: String, command: String, cwd: String, port: Int? = nil, startedBy: String = "User", branch: String? = nil) {
        self.id = id; self.project = project; self.name = name; self.command = command; self.cwd = cwd
        self.port = port; self.startedBy = startedBy; self.branch = branch; self.status = "stopped"; self.events = []
    }
}

public struct ServiceEvent: Codable, Equatable, Sendable {
    public var date: Date
    public var message: String
    public init(_ message: String, date: Date = Date()) { self.message = message; self.date = date }
}

public struct AIConnection: Codable, Equatable, Sendable {
    public var sessionID: String
    public var clientName: String
    public var clientVersion: String?
    public var connectedAt: Date
    public var lastSeen: Date
    public var lastUsedAt: Date?
    public var disconnectedAt: Date?
    public var isConnected: Bool
    public init(sessionID: String, clientName: String, clientVersion: String? = nil, connectedAt: Date = Date(), lastSeen: Date = Date(), lastUsedAt: Date? = nil, disconnectedAt: Date? = nil, isConnected: Bool = true) {
        self.sessionID = sessionID; self.clientName = clientName; self.clientVersion = clientVersion
        self.connectedAt = connectedAt; self.lastSeen = lastSeen; self.lastUsedAt = lastUsedAt; self.disconnectedAt = disconnectedAt; self.isConnected = isConnected
    }
}

public struct Request: Codable, Sendable {
    public var action: String
    public var service: Service?
    public var id: String?
    public var data: Data?
    public var offset: UInt64?
    public var columns: UInt16?
    public var rows: UInt16?
    public var actor: String?
    public var forceNew: Bool?
    public init(_ action: String, service: Service? = nil, id: String? = nil, data: Data? = nil, offset: UInt64? = nil, columns: UInt16? = nil, rows: UInt16? = nil, actor: String? = nil, forceNew: Bool? = nil) {
        self.action = action; self.service = service; self.id = id; self.data = data; self.offset = offset
        self.columns = columns; self.rows = rows; self.actor = actor; self.forceNew = forceNew
    }
}

public struct Response: Codable, Sendable {
    public var ok: Bool
    public var error: String?
    public var services: [Service]?
    public var data: Data?
    public var offset: UInt64?
    public var daemonPID: Int32?
    public var protocolVersion: Int?
    public var connections: [AIConnection]?
    public var reused: Bool?
    public init(ok: Bool = true, error: String? = nil, services: [Service]? = nil, data: Data? = nil, offset: UInt64? = nil, daemonPID: Int32? = nil, protocolVersion: Int? = nil, connections: [AIConnection]? = nil, reused: Bool? = nil) {
        self.ok = ok; self.error = error; self.services = services; self.data = data; self.offset = offset; self.daemonPID = daemonPID; self.protocolVersion = protocolVersion; self.connections = connections; self.reused = reused
    }
}

public enum ProcessesPaths {
    public static var root: URL {
        if let override = ProcessInfo.processInfo.environment["PROCESSES_HOME"], !override.isEmpty { return URL(fileURLWithPath: override, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RunDock", isDirectory: true)
    }
    public static var socket: String { root.appendingPathComponent("control.sock").path }
}
