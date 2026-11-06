import Foundation
import Darwin

/// Installs the bundled RunDock Codex skill only after an explicit user action in the app.
public enum AIIntegration {
    /// Returns the location where the Codex skill will be installed.
    /// `destinationRoot` is the Codex configuration directory (the directory containing
    /// `skills`), and exists primarily for tests.
    public static func codexSkillURL(destinationRoot: URL? = nil) -> URL {
        let root: URL
        if let destinationRoot {
            root = destinationRoot
        } else if let override = ProcessInfo.processInfo.environment["CODEX_HOME"], !override.isEmpty,
                  override.hasPrefix("/") {
            root = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
        }
        return root.appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent("rundock", isDirectory: true)
    }

    /// Copies the complete bundled `skills/rundock` directory into Codex's skill directory.
    /// Existing identical content is accepted; differing content is deliberately left for a
    /// future explicit update flow rather than silently replaced.
    @discardableResult
    public static func installCodexSkill(from sourceURL: URL, destinationRoot: URL? = nil) throws -> URL {
        let fm = FileManager.default
        if destinationRoot == nil, let override = ProcessInfo.processInfo.environment["CODEX_HOME"],
           !override.isEmpty, !override.hasPrefix("/") {
            throw RuntimeError("CODEX_HOME must be an absolute path; refusing relative Codex skill destination: \(override)")
        }
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory), !isDirectory.boolValue,
              sourceURL.lastPathComponent == "SKILL.md" else {
            throw RuntimeError("Bundled RunDock skill must point to skills/rundock/SKILL.md")
        }
        let sourceDirectory = sourceURL.deletingLastPathComponent()
        guard sourceDirectory.lastPathComponent == "rundock",
              sourceURL.standardizedFileURL.path.hasSuffix("/skills/rundock/SKILL.md") else {
            throw RuntimeError("Bundled RunDock skill must be inside skills/rundock")
        }
        let destination = codexSkillURL(destinationRoot: destinationRoot)
        try rejectSymlinkComponents(destinationRoot: codexRoot(destinationRoot: destinationRoot), destination: destination)
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        if fm.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw RuntimeError("Codex skill destination exists and is not a directory: \(destination.path)") }
            try rejectSymlinkComponents(destinationRoot: codexRoot(destinationRoot: destinationRoot), destination: destination)
            guard try directoriesEqual(sourceDirectory, destination, fileManager: fm) else {
                throw RuntimeError("A different RunDock skill already exists at \(destination.path). It was not overwritten; remove it or choose an explicit update flow.")
            }
            return destination
        }

        try fm.copyItem(at: sourceDirectory, to: destination)
        return destination
    }

    private static func codexRoot(destinationRoot: URL?) -> URL {
        codexSkillURL(destinationRoot: destinationRoot).deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func rejectSymlinkComponents(destinationRoot: URL, destination: URL) throws {
        let rootPath = destinationRoot.path
        let destinationPath = destination.path
        guard destinationPath == rootPath || destinationPath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else {
            throw RuntimeError("Codex skill destination is outside its configured root")
        }
        var current = destinationRoot
        try rejectIfSymlink(current)
        let suffix = String(destinationPath.dropFirst(rootPath.count)).split(separator: "/").map(String.init)
        for component in suffix {
            current.appendPathComponent(component)
            try rejectIfSymlink(current)
        }
    }

    private static func rejectIfSymlink(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & S_IFMT) != S_IFLNK else {
                throw RuntimeError("Codex skill destination contains a symbolic link: \(url.path)")
            }
        } else if errno != ENOENT {
            throw RuntimeError("Cannot inspect Codex skill destination \(url.path): \(String(cString: strerror(errno)))")
        }
    }

    private static func directoriesEqual(_ lhs: URL, _ rhs: URL, fileManager: FileManager) throws -> Bool {
        let left = try fileManager.subpathsOfDirectory(atPath: lhs.path).sorted()
        let right = try fileManager.subpathsOfDirectory(atPath: rhs.path).sorted()
        guard left == right else { return false }
        for path in left {
            let a = lhs.appendingPathComponent(path)
            let b = rhs.appendingPathComponent(path)
            let av = try a.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let bv = try b.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard av.isSymbolicLink != true, bv.isSymbolicLink != true,
                  av.isDirectory == bv.isDirectory else { return false }
            if av.isDirectory != true,
               try Data(contentsOf: a, options: .mappedIfSafe) != Data(contentsOf: b, options: .mappedIfSafe) { return false }
        }
        return true
    }
}
