import Foundation
import XCTest
import ProcessesProtocol

final class UpdateCheckerTests: XCTestCase {
    private func payload(tag: String = "v0.4.0", url: String? = nil, assetURL: String? = nil,
                         prerelease: Bool = false, draft: Bool = false) throws -> Data {
        let releaseURL = url ?? "https://github.com/example/rundock/releases/tag/\(tag)"
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let download = assetURL ?? "https://github.com/example/rundock/releases/download/\(tag)/RunDock-\(version)-arm64.dmg"
        return try JSONSerialization.data(withJSONObject: [
            "tag_name": tag, "name": tag, "body": "Release notes", "html_url": releaseURL,
            "prerelease": prerelease, "draft": draft,
            "assets": [["name": "RunDock-\(version)-arm64.dmg", "browser_download_url": download]]
        ])
    }

    func testDetectsStableUpdateAndMatchingDownloadAsset() throws {
        let result = try UpdateChecker.evaluate(data: payload(), repository: "example/rundock", currentVersion: "0.3.0", architecture: "arm64")
        guard case .updateAvailable(let release) = result else { return XCTFail("Expected update available") }
        XCTAssertEqual(release.tag, "v0.4.0")
        XCTAssertEqual(release.notes, "Release notes")
        XCTAssertEqual(release.downloadURL?.absoluteString, "https://github.com/example/rundock/releases/download/v0.4.0/RunDock-0.4.0-arm64.dmg")
    }

    func testReportsUpToDateUsingNumericSemverComparison() throws {
        let result = try UpdateChecker.evaluate(data: payload(tag: "v0.10.0"), repository: "example/rundock", currentVersion: "0.10.0", architecture: "arm64")
        XCTAssertEqual(result, .upToDate(currentVersion: "0.10.0", latestVersion: "v0.10.0"))
    }

    func testMissingOrUntrustedAssetDoesNotExposeDownloadURL() throws {
        let result = try UpdateChecker.evaluate(data: payload(assetURL: "https://evil.example/RunDock-0.4.0-arm64.dmg"), repository: "example/rundock", currentVersion: "0.3.0", architecture: "arm64")
        guard case .updateAvailable(let release) = result else { return XCTFail("Expected update available") }
        XCTAssertNil(release.downloadURL)
    }

    func testRejectsRepositoryInjectionMalformedVersionAndPrerelease() throws {
        XCTAssertThrowsError(try UpdateChecker.evaluate(data: payload(), repository: "example/rundock/extra", currentVersion: "0.3.0", architecture: "arm64"))
        XCTAssertThrowsError(try UpdateChecker.evaluate(data: payload(), repository: "example/rundock", currentVersion: "v0.3", architecture: "arm64"))
        XCTAssertThrowsError(try UpdateChecker.evaluate(data: payload(tag: "v0.4.0-beta", prerelease: true), repository: "example/rundock", currentVersion: "0.3.0", architecture: "arm64"))
    }
}
