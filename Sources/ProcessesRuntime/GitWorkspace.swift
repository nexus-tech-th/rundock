import Foundation
import Darwin
import ProcessesProtocol

private struct GitFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class GitOutput: @unchecked Sendable {
    var data = Data()
    var truncated = false
}

final class GitWorkspace: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let root = ProcessesPaths.root
    private let limit = 512 * 1024
    private var operationDeadline: Date?
    private var store: URL { root.appendingPathComponent("tasks.json") }
    private func fail(_ message: String) -> GitFailure { GitFailure(message: message) }
    private func canonical(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }
    private func records() throws -> [GitTask] {
        guard FileManager.default.fileExists(atPath: store.path) else { return [] }
        return try JSONDecoder().decode([GitTask].self, from: Data(contentsOf: store))
    }
    private func save(_ tasks: [GitTask]) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(tasks).write(to: store, options: .atomic)
        guard chmod(store.path, 0o600) == 0 else { throw fail("Cannot protect task state") }
    }
    // Drain all output to avoid blocking Git, retaining only the bounded prefix.
    private func git(_ cwd: String, _ args: [String], allowOne: Bool = false) throws -> (Data, Bool) {
        guard let operationDeadline, Date() < operationDeadline else { throw fail("Git operation timed out; check repository state before retrying") }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        p.arguments = ["-c", "core.quotepath=false"] + args
        var env = ProcessInfo.processInfo.environment
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_PREFIX", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT"] { env.removeValue(forKey: key) }
        env["GIT_ASKPASS"] = "/usr/bin/false"; env["SSH_ASKPASS"] = "/usr/bin/false"; env["SSH_ASKPASS_REQUIRE"] = "never"
        env["GIT_TERMINAL_PROMPT"] = "0"; env["GIT_LITERAL_PATHSPECS"] = "1"; env["GIT_PAGER"] = "cat"; env["GIT_OPTIONAL_LOCKS"] = "0"
        let pipe = Pipe(), output = GitOutput(), completed = DispatchGroup()
        p.environment = env; p.standardOutput = pipe; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        try p.run()
        try? pipe.fileHandleForWriting.close()
        completed.enter()
        DispatchQueue.global(qos: .utility).async { [limit] in
            defer { completed.leave(); try? pipe.fileHandleForReading.close() }
            while true {
                let chunk = pipe.fileHandleForReading.readData(ofLength: 16384)
                if chunk.isEmpty { break }
                let remaining = max(0, limit - output.data.count)
                output.data.append(chunk.prefix(remaining))
                if chunk.count > remaining { output.truncated = true }
            }
        }
        let deadline = min(Date(timeIntervalSinceNow: 10), operationDeadline)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        let timedOut = p.isRunning
        if timedOut {
            p.terminate()
            let grace = min(Date(timeIntervalSinceNow: 1), operationDeadline.addingTimeInterval(1))
            while p.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.05) }
            if p.isRunning { _ = kill(p.processIdentifier, SIGKILL) }
        }
        p.waitUntilExit()
        let outputWait = max(0, min(2, operationDeadline.addingTimeInterval(1).timeIntervalSinceNow))
        guard completed.wait(timeout: .now() + outputWait) == .success else { throw fail("Git output did not close; check repository state before retrying") }
        if timedOut { throw fail("Git operation timed out; check repository state before retrying") }
        guard p.terminationStatus == 0 || (allowOne && p.terminationStatus == 1) else { throw fail("Git \(args.first ?? "operation") failed (exit \(p.terminationStatus))") }
        return (output.data, output.truncated)
    }
    private func line(_ cwd: String, _ args: [String]) throws -> String {
        let (data, truncated) = try git(cwd, args)
        guard !truncated, let text = String(data: data, encoding: .utf8) else { throw fail("Invalid Git output") }
        return text.trimmingCharacters(in: .newlines)
    }
    private func checked(_ id: String?) throws -> GitTask {
        guard let id, let task = try records().first(where: { $0.id == id }) else { throw fail("Task not found") }
        guard FileManager.default.fileExists(atPath: task.worktreePath), canonical(task.worktreePath) == task.worktreePath,
              try canonical(line(task.worktreePath, ["rev-parse", "--show-toplevel"])) == task.worktreePath,
              try line(task.worktreePath, ["branch", "--show-current"]) == task.branch else { throw fail("Task worktree is missing or changed") }
        let sourceCommon = try line(task.repositoryPath, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
        let taskCommon = try line(task.worktreePath, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
        guard canonical(sourceCommon) == canonical(taskCommon) else { throw fail("Task worktree repository changed") }
        return task
    }
    func resolve(_ id: String, cwd: String?) throws -> String {
        guard lock.try() else { throw fail("Git workspace is busy; retry shortly") }
        operationDeadline = Date(timeIntervalSinceNow: 60)
        defer { operationDeadline = nil; lock.unlock() }
        let task = try checked(id)
        guard let cwd, !cwd.isEmpty else { return task.worktreePath }
        let path = canonical(cwd)
        var directory: ObjCBool = false
        guard (path == task.worktreePath || path.hasPrefix(task.worktreePath + "/")), FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else { throw fail("Working directory must be inside task worktree") }
        return path
    }
    private func safePaths(_ paths: [String]?, in root: String, single: Bool = false) throws -> [String] {
        guard let paths, !paths.isEmpty, paths.count <= 256, !single || paths.count == 1 else { throw fail("Explicit file paths required") }
        for path in paths {
            guard !path.isEmpty, path.utf8.count <= 4096, !path.hasPrefix("/"), !path.contains("\0"), !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." || $0 == "." || $0.isEmpty || $0.lowercased() == ".git" }) else { throw fail("Invalid file path") }
            let resolved = canonical(root + "/" + path)
            guard resolved.hasPrefix(root + "/") else { throw fail("File path escapes task worktree") }
        }
        return paths
    }
    func handle(_ req: Request) throws -> Response {
        guard lock.try() else { throw fail("Git workspace is busy; retry shortly") }
        operationDeadline = Date(timeIntervalSinceNow: 60)
        defer { operationDeadline = nil; lock.unlock() }
        if req.action == "task-list" { return Response(tasks: try records()) }
        if req.action == "task-ensure" {
            guard let key = req.taskKey, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, key.utf8.count <= 512,
                  let repo = req.repositoryPath, repo.hasPrefix("/"), let name = req.taskName, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 128,
                  let client = req.clientName, !client.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, client.utf8.count <= 128 else { throw fail("Task key, repository, name and client required") }
            let source = canonical(try line(canonical(repo), ["rev-parse", "--show-toplevel"]))
            var tasks = try records()
            let sourceCommon = canonical(try line(source, ["rev-parse", "--path-format=absolute", "--git-common-dir"]))
            for existing in tasks where existing.taskKey == key {
                let existingCommon = try? line(existing.repositoryPath, ["rev-parse", "--path-format=absolute", "--git-common-dir"])
                if existing.repositoryPath == source || existingCommon.map(canonical) == sourceCommon {
                    return Response(reused: true, task: try checked(existing.id))
                }
            }
            let id = UUID().uuidString.lowercased()
            let slug = String(name.lowercased().unicodeScalars.map { scalar -> Character in
                ((97...122).contains(scalar.value) || (48...57).contains(scalar.value)) ? Character(scalar) : "-"
            }.prefix(32)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            let branch = "rundock/\(slug.isEmpty ? "task" : slug)-\(id)"
            let dir = root.appendingPathComponent("worktrees", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let path = canonical(dir.appendingPathComponent(id).path)
            _ = try git(source, ["worktree", "add", "-b", branch, path, "HEAD"])
            let task = GitTask(id: id, name: name, taskKey: key, repositoryPath: source, worktreePath: canonical(path), branch: branch, client: client)
            tasks.append(task)
            do { try save(tasks) } catch {
                _ = try? git(source, ["worktree", "remove", path]); _ = try? git(source, ["branch", "-d", branch]); throw error
            }
            return Response(reused: false, task: task)
        }
        let task = try checked(req.taskID), cwd = task.worktreePath
        switch req.action {
        case "git-status":
            let (data, truncated) = try git(cwd, ["status", "--porcelain=v1", "-z", "--untracked-files=all"])
            guard !truncated else { throw fail("Git status exceeds output limit") }
            let entries = data.split(separator: 0, omittingEmptySubsequences: true); var changes: [GitChange] = []; var i = 0
            while i < entries.count {
                let bytes = Array(entries[i]); guard bytes.count >= 4, bytes[2] == 32, let path = String(bytes: bytes.dropFirst(3), encoding: .utf8) else { throw fail("Invalid Git status output") }
                let x = String(UnicodeScalar(bytes[0])), y = String(UnicodeScalar(bytes[1])); var original: String?
                if x == "R" || x == "C" || y == "R" || y == "C" { i += 1; guard i < entries.count, let value = String(bytes: entries[i], encoding: .utf8) else { throw fail("Invalid Git rename output") }; original = value }
                changes.append(GitChange(path: path, originalPath: original, indexStatus: x, worktreeStatus: y)); i += 1
            }
            return Response(gitStatus: changes, truncated: false)
        case "git-diff":
            let path = try safePaths(req.paths, in: cwd, single: true)[0]
            let untracked = try git(cwd, ["ls-files", "-z", "--others", "--exclude-standard", "--", path]).0 == Data((path + "\0").utf8)
            let result: (Data, Bool)
            if untracked && req.staged != true { result = try git(cwd, ["diff", "--no-ext-diff", "--no-index", "--", "/dev/null", path], allowOne: true) }
            else { result = try git(cwd, ["diff", "--no-ext-diff"] + (req.staged == true ? ["--cached"] : []) + ["--", path]) }
            return Response(text: String(decoding: result.0, as: UTF8.self), truncated: result.1)
        case "git-stage": _ = try git(cwd, ["add", "--"] + safePaths(req.paths, in: cwd)); return Response()
        case "git-unstage": _ = try git(cwd, ["restore", "--staged", "--"] + safePaths(req.paths, in: cwd)); return Response()
        case "git-commit":
            guard let message = req.message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, message.utf8.count <= 8192, !message.contains("\0") else { throw fail("Commit message required") }
            _ = try git(cwd, ["commit", "-m", message]); return Response()
        case "git-push":
            if (try? line(cwd, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}"])) != nil {
                let remote = try line(cwd, ["config", "--get", "branch.\(task.branch).remote"])
                let merge = try line(cwd, ["config", "--get", "branch.\(task.branch).merge"])
                guard !remote.isEmpty, merge.hasPrefix("refs/heads/") else { throw fail("Invalid upstream configuration") }
                _ = try git(cwd, ["check-ref-format", merge])
                _ = try git(cwd, ["push", "--", remote, "HEAD:\(merge)"])
            } else { _ = try git(cwd, ["push", "--set-upstream", "--", "origin", "HEAD:refs/heads/\(task.branch)"]) }
            return Response()
        default: throw fail("Unknown Git action")
        }
    }
}
