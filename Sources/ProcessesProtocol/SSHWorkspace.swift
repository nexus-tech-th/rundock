import Foundation
import Darwin

public struct SSHHost: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var host: String
    public var user: String
    public var port: Int
    public var keyPath: String?
    public var group: String?

    public init(id: String = UUID().uuidString.lowercased(), name: String, host: String, user: String, port: Int = 22, keyPath: String? = nil, group: String? = nil) {
        self.id = id; self.name = name; self.host = host; self.user = user; self.port = port; self.keyPath = keyPath; self.group = group
    }

    public func validate() throws {
        func valid(_ value: String, allowed: CharacterSet) -> Bool {
            !value.isEmpty && value.utf8.count <= 255 && !value.hasPrefix("-") && value.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
        let hostCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:")
        let userCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 128,
              valid(host, allowed: hostCharacters), valid(user, allowed: userCharacters), (1...65535).contains(port),
              !id.isEmpty, id.utf8.count <= 64, id.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0) }),
              (group?.utf8.count ?? 0) <= 128 else { throw SSHWorkspaceError.invalidHost }
        if let keyPath, !keyPath.isEmpty {
            guard keyPath.hasPrefix("/"), keyPath.utf8.count <= 4096, !keyPath.contains("\0"), !keyPath.contains("\n"), !keyPath.contains("\r") else { throw SSHWorkspaceError.invalidKeyPath }
        }
    }

    // An SSH subprocess always receives separate arguments; this quoting is only
    // for a terminal command executed through the existing managed shell.
    public func terminalCommand() throws -> String {
        try validate()
        var args = ["/usr/bin/ssh", "-t", "-o", "StrictHostKeyChecking=ask", "-p", String(port)]
        if let keyPath, !keyPath.isEmpty { args += ["-i", keyPath] }
        args += ["-l", user, host]
        return args.map(Self.shellQuote).joined(separator: " ")
    }
    public func keyAgentCommand() throws -> String? {
        try validate()
        guard let keyPath, !keyPath.isEmpty else { return nil }
        return ["/usr/bin/ssh-add", keyPath].map(Self.shellQuote).joined(separator: " ")
    }
    private static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

public enum SSHWorkspaceError: Error, LocalizedError {
    case invalidHost, invalidKeyPath, invalidStore, protocolError(String), remote(String)
    public var errorDescription: String? {
        switch self {
        case .invalidHost: return "Invalid SSH host settings"
        case .invalidKeyPath: return "The key must be an absolute file path"
        case .invalidStore: return "Invalid SSH host store"
        case .protocolError(let text), .remote(let text): return text
        }
    }
}

public enum SSHHostStore {
    public static func load() throws -> [SSHHost] {
        let url = ProcessesPaths.root.appendingPathComponent("ssh-hosts.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let hosts = try JSONDecoder().decode([SSHHost].self, from: Data(contentsOf: url))
        guard hosts.count <= 256, Set(hosts.map(\.id)).count == hosts.count else { throw SSHWorkspaceError.invalidStore }
        for host in hosts { try host.validate() }; return hosts
    }
    public static func save(_ hosts: [SSHHost]) throws {
        guard hosts.count <= 256, Set(hosts.map(\.id)).count == hosts.count else { throw SSHWorkspaceError.invalidStore }
        for host in hosts { try host.validate() }
        let root = ProcessesPaths.root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = root.appendingPathComponent("ssh-hosts.json")
        let temporary = root.appendingPathComponent(".ssh-hosts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw SSHWorkspaceError.invalidStore }
        let file = try FileHandle(forWritingTo: temporary)
        do { try file.write(contentsOf: JSONEncoder().encode(hosts)); try file.close() }
        catch { try? file.close(); throw error }
        guard rename(temporary.path, url.path) == 0 else { throw SSHWorkspaceError.invalidStore }
    }
}
