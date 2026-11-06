import AppKit
import SwiftUI
import SwiftTerm
import ProcessesProtocol

@MainActor final class TerminalAppearance: ObservableObject {
    static let shared = TerminalAppearance()
    @Published private(set) var profiles: [ITermTheme] = []
    @Published private(set) var theme: ITermTheme?
    @Published private(set) var problem: String?
    @Published var source: String { didSet { UserDefaults.standard.set(source, forKey: "terminalThemeSource"); reload() } }
    @Published var profileID: String { didSet { UserDefaults.standard.set(profileID, forKey: "terminalThemeProfile"); reload() } }
    @Published private(set) var revision = UUID()
    private var imported: ITermTheme?
    private var activationObserver: NSObjectProtocol?
    var preferenceURL: URL {
        if let path = UserDefaults.standard.string(forKey: "iTermPreferencePath") { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/com.googlecode.iterm2.plist")
    }
    private init() {
        source = UserDefaults.standard.string(forKey: "terminalThemeSource") ?? "iterm"
        profileID = UserDefaults.standard.string(forKey: "terminalThemeProfile") ?? "default"
        if let data = UserDefaults.standard.data(forKey: "importedTerminalTheme") { imported = try? JSONDecoder().decode(ITermTheme.self, from: data) }
        reload()
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }
    func reload() {
        let old = theme
        problem = nil
        do {
            let result = try ITermThemeReader.loadProfiles(from: preferenceURL)
            profiles = result.profiles
            if source == "iterm" {
                theme = profileID == "default" ? result.defaultProfile : profiles.first { $0.id == profileID }
                if theme == nil { problem = "The selected iTerm2 profile is unavailable. Choose a profile or preferences file." }
            } else { theme = source == "imported" ? imported : nil }
        } catch {
            profiles = []
            theme = source == "imported" ? imported : nil
            if source == "iterm" { problem = "iTerm2 preferences could not be read. Choose its preferences file or import an .itermcolors file." }
        }
        if theme != old { revision = UUID() }
    }
    func choosePreferences() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose iTerm2’s com.googlecode.iterm2.plist preferences file. It will only be read."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: "iTermPreferencePath")
        source = "iterm"; reload()
    }
    func importColors() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose an exported iTerm2 .itermcolors theme."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let value = try ITermThemeReader.loadColorScheme(from: url)
            guard !value.ansiColors.isEmpty || value.background != nil || value.foreground != nil else { throw RuntimeError("This file contains no terminal colors.") }
            imported = value
            UserDefaults.standard.set(try JSONEncoder().encode(value), forKey: "importedTerminalTheme")
            source = "imported"; reload()
        } catch { problem = error.localizedDescription }
    }
    func apply(to view: TerminalView) {
        let fallback = NSColor(calibratedRed: 0.095, green: 0.105, blue: 0.11, alpha: 1)
        view.nativeBackgroundColor = theme?.background.map(native) ?? fallback
        view.nativeForegroundColor = theme?.foreground.map(native) ?? NSColor(calibratedRed: 0.85, green: 0.89, blue: 0.87, alpha: 1)
        view.caretColor = theme?.cursor.map(native) ?? view.nativeForegroundColor
        view.selectedTextBackgroundColor = theme?.selection.map(native) ?? NSColor.selectedTextBackgroundColor
        if let theme, theme.ansiColors.count == 16 {
            view.installColors((0..<16).map { index in
                let c = native(theme.ansiColors[index]!).usingColorSpace(.sRGB) ?? native(theme.ansiColors[index]!)
                return SwiftTerm.Color(red: UInt16((c.redComponent * 65535).rounded()), green: UInt16((c.greenComponent * 65535).rounded()), blue: UInt16((c.blueComponent * 65535).rounded()))
            })
        } else {
            let colors: [UInt32] = [0x000000, 0xcd0000, 0x00cd00, 0xcdcd00, 0x0000ee, 0xcd00cd, 0x00cdcd, 0xe5e5e5, 0x7f7f7f, 0xff0000, 0x00ff00, 0xffff00, 0x5c5cff, 0xff00ff, 0x00ffff, 0xffffff]
            view.installColors(colors.map { SwiftTerm.Color(red: UInt16(($0 >> 16) & 255) * 257, green: UInt16(($0 >> 8) & 255) * 257, blue: UInt16($0 & 255) * 257) })
        }
        let size = min(48, max(8, theme?.fontSize ?? 12))
        view.font = theme?.font.flatMap { NSFont(name: $0, size: size) } ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
    private func native(_ c: ProcessesProtocol.RGBColor) -> NSColor {
        if c.colorSpace == "P3" { return NSColor(displayP3Red: c.red, green: c.green, blue: c.blue, alpha: 1) }
        return NSColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
    }
}

struct TerminalAppearanceView: View {
    @ObservedObject private var appearance = TerminalAppearance.shared
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("Terminal appearance").font(.system(size: 21, weight: .semibold)); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("Use the colors and font from your iTerm2 profile. RunDock reads it again when you return to the app; iTerm2 settings stay unchanged.").font(.system(size: 13)).foregroundStyle(Palette.muted)
            Picker("Theme source", selection: $appearance.source) {
                Text("Follow iTerm2").tag("iterm")
                Text("RunDock").tag("rundock")
                Text("Imported colors").tag("imported")
            }.pickerStyle(.segmented)
            if appearance.source == "iterm" {
                Picker("Profile", selection: $appearance.profileID) {
                    Text("iTerm2 default profile").tag("default")
                    ForEach(appearance.profiles.indices, id: \.self) { index in
                        if let id = appearance.profiles[index].id { Text(appearance.profiles[index].name ?? "Profile").tag(id) }
                    }
                }
                Text(appearance.preferenceURL.path).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled)
                HStack { Button("Refresh") { appearance.reload() }; Button("Choose Preferences…") { appearance.choosePreferences() } }
            }
            HStack { Button("Import .itermcolors…") { appearance.importColors() }; Spacer(); Text(appearance.theme?.name ?? (appearance.source == "iterm" ? "No profile loaded" : "RunDock colors")).font(.system(size: 12)).foregroundStyle(Palette.muted) }
            if let theme = appearance.theme {
                HStack(spacing: 4) { ForEach(0..<16) { index in
                    if let c = theme.ansiColors[index] { Rectangle().fill(SwiftUI.Color(red: c.red, green: c.green, blue: c.blue)).frame(height: 28) }
                } }.clipShape(RoundedRectangle(cornerRadius: 5))
                Text("Font: \(theme.font ?? "System monospace") · \(Int(theme.fontSize ?? 12)) pt").font(.system(size: 12))
            }
            if let problem = appearance.problem { Label(problem, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.orange) }
            Divider()
            Text("Prompt themes such as Powerlevel10k come from your shell configuration. A colors file does not include shell plugins, prompt settings, transparency or iTerm2 keyboard mappings.").font(.system(size: 12)).foregroundStyle(Palette.muted)
        }.padding(24).frame(width: 600).background(Palette.panel)
    }
}
