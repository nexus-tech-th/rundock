import Foundation
import XCTest
import ProcessesProtocol

final class ITermThemeTests: XCTestCase {
    private func writePlist(_ value: Any) throws -> URL {
        let url = URL(fileURLWithPath: "/private/tmp/iterm-theme-\(UUID().uuidString).plist")
        let data = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        try data.write(to: url)
        return url
    }

    private func rgb(_ r: Any, _ g: Any, _ b: Any, space: Any = 1) -> [String: Any] {
        ["Red Component": r, "Green Component": g, "Blue Component": b, "Color Space": space]
    }

    func testReadsDefaultProfileFontAndSixteenANSIColors() throws {
        let colors = Dictionary(uniqueKeysWithValues: (0..<16).map { ("Ansi \($0) Color", rgb(Double($0) / 15, 0.25, 0.75)) })
        var profile: [String: Any] = ["Guid": "chosen", "Name": "Night", "Normal Font": "MesloLGS NF Regular",
                                      "Font Size": 13, "Foreground Color": rgb(1, 1, 1), "Background Color": rgb(0, 0, 0)]
        colors.forEach { profile[$0.key] = $0.value }
        let url = try writePlist(["Default Bookmark Guid": "chosen", "New Bookmarks": [
            ["Guid": "other", "Name": "Other"], profile
        ]])
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try ITermThemeReader.loadProfiles(from: url)
        XCTAssertEqual(result.defaultProfileID, "chosen")
        XCTAssertEqual(result.defaultProfile?.name, "Night")
        XCTAssertEqual(result.defaultProfile?.font, "MesloLGS NF Regular")
        XCTAssertEqual(result.defaultProfile?.fontSize, 13)
        XCTAssertEqual(result.defaultProfile?.ansiColors.count, 16)
        XCTAssertEqual(result.defaultProfile?.ansiColors[15]?.red, 1)
    }

    func testMalformedAndOutOfRangeColorComponentsAreSafe() throws {
        let url = try writePlist(["Default Bookmark Guid": "x", "New Bookmarks": [[
            "Guid": "x", "Font Size": "nan", "Normal Font": "Font With Spaces",
            "Foreground Color": rgb("2.5", "-1", "0.5", space: 2),
            "Background Color": ["Red Component": "infinity", "Green Component": 0, "Blue Component": 0],
            "Ansi 0 Color": ["Red Component": "broken", "Green Component": 0, "Blue Component": 0]
        ]]])
        defer { try? FileManager.default.removeItem(at: url) }
        let theme = try XCTUnwrap(ITermThemeReader.loadProfiles(from: url).defaultProfile)
        XCTAssertNil(theme.fontSize)
        XCTAssertEqual(theme.font, "Font With Spaces")
        XCTAssertEqual(theme.foreground, RGBColor(red: 1, green: 0, blue: 0.5, colorSpace: "P3"))
        XCTAssertNil(theme.background)
        XCTAssertNil(theme.ansiColors[0])
    }

    func testActualItermFontAndColorSpaceSchema() throws {
        let url = try writePlist(["Default Bookmark Guid": "actual", "New Bookmarks": [[
            "Guid": "actual", "Normal Font": "MesloLGS-NF-Regular 13",
            "Foreground Color": ["Red Component": 1, "Green Component": 1, "Blue Component": 1, "Color Space": "sRGB"],
            "Selection Color": ["Red Component": 0.1, "Green Component": 0.2, "Blue Component": 0.3, "Color Space": "P3"],
            "Selected Text Color": ["Red Component": 1, "Green Component": 0.8, "Blue Component": 0, "Color Space": "P3"]
        ]]])
        defer { try? FileManager.default.removeItem(at: url) }
        let theme = try XCTUnwrap(ITermThemeReader.loadProfiles(from: url).defaultProfile)
        XCTAssertEqual(theme.font, "MesloLGS-NF-Regular")
        XCTAssertEqual(theme.fontSize, 13)
        XCTAssertEqual(theme.foreground?.colorSpace, "sRGB")
        XCTAssertEqual(theme.selection?.colorSpace, "P3")
        XCTAssertEqual(theme.selectionForeground?.red, 1)
    }

    func testDefaultGuidWithoutMatchingProfileReturnsNoDefault() throws {
        let url = try writePlist(["Default Bookmark Guid": "missing", "New Bookmarks": [["Guid": "present"]]])
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try ITermThemeReader.loadProfiles(from: url)
        XCTAssertNil(result.defaultProfile)
        XCTAssertEqual(result.profiles.count, 1)
    }
}
