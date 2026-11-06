import Foundation

public struct GitTask: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var taskKey: String
    public var repositoryPath: String
    public var worktreePath: String
    public var branch: String
    public var client: String
    public var createdAt: Date
    public init(id: String, name: String, taskKey: String, repositoryPath: String, worktreePath: String, branch: String, client: String, createdAt: Date = Date()) {
        self.id = id; self.name = name; self.taskKey = taskKey; self.repositoryPath = repositoryPath; self.worktreePath = worktreePath; self.branch = branch; self.client = client; self.createdAt = createdAt
    }
}

public struct GitChange: Codable, Equatable, Sendable {
    public var path: String
    public var originalPath: String?
    public var indexStatus: String
    public var worktreeStatus: String
    public init(path: String, originalPath: String? = nil, indexStatus: String, worktreeStatus: String) {
        self.path = path; self.originalPath = originalPath; self.indexStatus = indexStatus; self.worktreeStatus = worktreeStatus
    }
}
