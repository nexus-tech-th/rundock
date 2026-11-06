import Foundation

public struct UpdateRelease: Codable, Equatable, Sendable {
    public let version: String
    public let tag: String
    public let notes: String
    public let releaseURL: URL
    public let downloadURL: URL?
}

public enum UpdateCheckResult: Equatable, Sendable {
    case upToDate(currentVersion: String, latestVersion: String)
    case updateAvailable(UpdateRelease)
}

public enum UpdateCheckerError: Error, Equatable {
    case repositoryNotConfigured
    case invalidRepository
    case invalidVersion
    case invalidRelease
    case httpStatus(Int)
}

/// Read-only GitHub Releases checker. It never installs or launches downloaded files.
public enum UpdateChecker {
    private struct GitHubRelease: Decodable {
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: String
        let prerelease: Bool
        let draft: Bool
        let assets: [Asset]
    }

    /// repository must be the publisher's `owner/repository`; no default feed is assumed.
    public static func check(repository: String?, currentVersion: String, architecture: String,
                             session: URLSession = .shared) async throws -> UpdateCheckResult {
        guard let repository, !repository.isEmpty else { throw UpdateCheckerError.repositoryNotConfigured }
        let parts = try repositoryParts(repository)
        guard validVersion(currentVersion) != nil else { throw UpdateCheckerError.invalidVersion }
        let endpoint = URL(string: "https://api.github.com/repos/\(parts.owner)/\(parts.repository)/releases/latest")!
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("RunDock update checker", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateCheckerError.invalidRelease }
        guard (200..<300).contains(http.statusCode) else { throw UpdateCheckerError.httpStatus(http.statusCode) }
        return try evaluate(data: data, repository: repository, currentVersion: currentVersion, architecture: architecture)
    }

    /// Evaluates a GitHub latest-release response. Exposed to keep parsing testable without network access.
    public static func evaluate(data: Data, repository: String, currentVersion: String,
                                architecture: String) throws -> UpdateCheckResult {
        let parts = try repositoryParts(repository)
        guard let current = validVersion(currentVersion) else { throw UpdateCheckerError.invalidVersion }
        guard architecture == "arm64" || architecture == "x86_64" else { throw UpdateCheckerError.invalidRelease }
        let release: GitHubRelease
        do { release = try JSONDecoder().decode(GitHubRelease.self, from: data) }
        catch { throw UpdateCheckerError.invalidRelease }
        guard !release.prerelease, !release.draft,
              let latest = validVersion(release.tag_name), let releaseURL = safeReleaseURL(release.html_url, parts: parts, tag: release.tag_name) else {
            throw UpdateCheckerError.invalidRelease
        }
        guard latest > current else { return .upToDate(currentVersion: currentVersion, latestVersion: release.tag_name) }
        let filename = "RunDock-\(release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name)-\(architecture).dmg"
        let expected = URL(string: "https://github.com/\(parts.owner)/\(parts.repository)/releases/download/\(release.tag_name)/\(filename)")!
        let download = release.assets.first { asset in
            asset.name == filename && URL(string: asset.browser_download_url) == expected
        }.flatMap { _ in expected }
        return .updateAvailable(UpdateRelease(version: release.name ?? release.tag_name, tag: release.tag_name,
                                              notes: release.body ?? "", releaseURL: releaseURL, downloadURL: download))
    }

    private static func repositoryParts(_ value: String) throws -> (owner: String, repository: String) {
        let pieces = value.split(separator: "/", omittingEmptySubsequences: false)
        func valid(_ s: Substring) -> Bool {
            !s.isEmpty && s.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil && s != "." && s != ".."
        }
        guard pieces.count == 2, valid(pieces[0]), valid(pieces[1]) else { throw UpdateCheckerError.invalidRepository }
        return (String(pieces[0]), String(pieces[1]))
    }

    private static func safeReleaseURL(_ value: String, parts: (owner: String, repository: String), tag: String) -> URL? {
        let expected = URL(string: "https://github.com/\(parts.owner)/\(parts.repository)/releases/tag/\(tag)")
        guard let url = URL(string: value), url == expected else { return nil }
        return url
    }

    /// Strict stable SemVer, accepting an optional leading `v`; prerelease/build metadata is excluded.
    private static func validVersion(_ value: String) -> [UInt64]? {
        let raw = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let components = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3, components.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let numbers = components.compactMap { UInt64($0) }
        guard numbers.count == 3 else { return nil }
        return numbers
    }
}

private func > (lhs: [UInt64], rhs: [UInt64]) -> Bool {
    for (a, b) in zip(lhs, rhs) { if a != b { return a > b } }
    return false
}
