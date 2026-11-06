import Foundation

/// An sRGB-ready color. The source color-space label is retained so a renderer
/// can make a more precise conversion when the preference contains P3 data.
public struct RGBColor: Codable, Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let colorSpace: String?

    public init(red: Double, green: Double, blue: Double, colorSpace: String? = nil) {
        self.red = Self.unit(red); self.green = Self.unit(green); self.blue = Self.unit(blue)
        self.colorSpace = colorSpace
    }

    private static func unit(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }
}

public struct ITermTheme: Codable, Equatable, Sendable {
    public let id: String?
    public let name: String?
    public let font: String?
    public let fontSize: Double?
    public let foreground: RGBColor?
    public let background: RGBColor?
    public let cursor: RGBColor?
    public let selection: RGBColor?
    public let selectionForeground: RGBColor?
    /// iTerm ANSI slots 0 through 15.
    public let ansiColors: [Int: RGBColor]

    public init(id: String? = nil, name: String? = nil, font: String? = nil, fontSize: Double? = nil,
                foreground: RGBColor? = nil, background: RGBColor? = nil, cursor: RGBColor? = nil,
                selection: RGBColor? = nil, selectionForeground: RGBColor? = nil, ansiColors: [Int: RGBColor] = [:]) {
        self.id = id; self.name = name; self.font = font; self.fontSize = fontSize
        self.foreground = foreground; self.background = background; self.cursor = cursor
        self.selection = selection; self.selectionForeground = selectionForeground; self.ansiColors = ansiColors
    }
}

public struct ITermThemeProfiles: Equatable, Sendable {
    public let profiles: [ITermTheme]
    public let defaultProfileID: String?
    public var defaultProfile: ITermTheme? {
        guard let id = defaultProfileID else { return nil }
        return profiles.first { $0.id == id }
    }
}

/// Read-only parser for iTerm2 preference plists and exported `.itermcolors` files.
public enum ITermThemeReader {
    /// Parses a plist URL, accepting both XML and binary property lists.
    public static func loadProfiles(from url: URL) throws -> ITermThemeProfiles {
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let root = object as? [String: Any] else { return ITermThemeProfiles(profiles: [], defaultProfileID: nil) }
        let rows = (root["New Bookmarks"] as? [[String: Any]]) ?? []
        let profiles = rows.map(parseProfile)
        let defaultID = root["Default Bookmark Guid"] as? String
        return ITermThemeProfiles(profiles: profiles, defaultProfileID: defaultID)
    }

    /// Parses one exported `.itermcolors` dictionary as a theme without an ID.
    public static func loadColorScheme(from url: URL) throws -> ITermTheme {
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let root = object as? [String: Any] else { return ITermTheme() }
        return parseProfile(root)
    }

    private static func parseProfile(_ row: [String: Any]) -> ITermTheme {
        var ansi: [Int: RGBColor] = [:]
        for i in 0..<16 {
            if let color = color(row["Ansi \(i) Color"]) { ansi[i] = color }
        }
        let rawFont = row["Normal Font"] as? String
        let parsedFont = fontNameAndSize(rawFont)
        let size = number(row["Font Size"]).flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? parsedFont.size
        return ITermTheme(
            id: row["Guid"] as? String,
            name: row["Name"] as? String,
            font: parsedFont.name,
            fontSize: size,
            foreground: color(row["Foreground Color"]),
            background: color(row["Background Color"]),
            cursor: color(row["Cursor Color"]),
            selection: color(row["Selection Color"]),
            selectionForeground: color(row["Selected Text Color"]),
            ansiColors: ansi
        )
    }

    private static func color(_ value: Any?) -> RGBColor? {
        guard let d = value as? [String: Any],
              let r = number(d["Red Component"]), let g = number(d["Green Component"]), let b = number(d["Blue Component"]),
              r.isFinite, g.isFinite, b.isFinite else { return nil }
        let space: String?
        if let named = d["Color Space"] as? String { space = named }
        else if let named = d["Color Space Name"] as? String { space = named }
        else if let raw = number(d["Color Space"]) {
            switch Int(raw) { case 1: space = "sRGB"; case 2: space = "P3"; case 0: space = "Calibrated RGB"; default: space = "iTerm color space \(Int(raw))" }
        } else { space = nil }
        return RGBColor(red: r, green: g, blue: b, colorSpace: space)
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func fontNameAndSize(_ value: String?) -> (name: String?, size: Double?) {
        guard let value else { return (nil, nil) }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let split = trimmed.range(of: #"\s+\d+(?:\.\d+)?$"#, options: .regularExpression) else { return (trimmed.isEmpty ? nil : trimmed, nil) }
        let sizeStart = trimmed[split].firstIndex(where: { $0.isNumber })!
        let size = Double(trimmed[sizeStart...])
        let name = String(trimmed[..<split.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? trimmed : name, size)
    }
}
