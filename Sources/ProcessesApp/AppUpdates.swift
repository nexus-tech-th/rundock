import SwiftUI
import AppKit
import ProcessesProtocol

@MainActor final class AppUpdates: ObservableObject {
    static let shared = AppUpdates()
    @Published var checking = false
    @Published var release: UpdateRelease?
    @Published var message = "Check for a newer RunDock release."
    @Published var automatic: Bool {
        didSet { UserDefaults.standard.set(automatic, forKey: "automaticUpdateChecks") }
    }
    var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.4.1" }
    var repository: String? { Bundle.main.object(forInfoDictionaryKey: "RunDockUpdateRepository") as? String }
    private var timer: Timer?
    private init() {
        automatic = UserDefaults.standard.object(forKey: "automaticUpdateChecks") as? Bool ?? true
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.checkIfDue() }
        }
    }
    func checkIfDue() async {
        guard automatic, repository != nil else { return }
        let last = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast
        if Date().timeIntervalSince(last) >= 86400 { await check() }
    }
    func check() async {
        guard !checking else { return }
        guard let repository, !repository.isEmpty else {
            message = "Updates are not published for this preview yet. A publisher release repository will be included in the public build."
            return
        }
        checking = true; release = nil; message = "Checking for updates…"
        defer { checking = false }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x86_64"
        #endif
        do {
            switch try await UpdateChecker.check(repository: repository, currentVersion: version, architecture: architecture) {
            case .upToDate: message = "You’re up to date. RunDock \(version) is the latest version."
            case .updateAvailable(let value): release = value; message = "RunDock \(value.tag) is available."
            }
            UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
        } catch {
            if (error as? UpdateCheckerError) == .httpStatus(404) { message = "No public release was found in the configured repository yet." }
            else { message = "Could not check for updates. Try again later." }
        }
    }
}

struct AppUpdatesView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var updates = AppUpdates.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text("RunDock updates").font(.system(size: 21, weight: .semibold)); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("Installed version \(updates.version)").font(.system(size: 12)).foregroundStyle(Palette.muted)
            HStack(spacing: 10) {
                if updates.checking { ProgressView().controlSize(.small) }
                Text(updates.message).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            }
            Toggle("Automatically check once a day", isOn: $updates.automatic).font(.system(size: 12))
            if let release = updates.release {
                ScrollView { Text(release.notes).font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 180)
                HStack {
                    if let download = release.downloadURL { Link("Download DMG", destination: download).buttonStyle(MintButtonStyle()) }
                    Link("Release notes ↗", destination: release.releaseURL).font(.system(size: 12))
                }
            }
            HStack { Button(updates.checking ? "Checking…" : "Check Now") { Task { await updates.check() } }.disabled(updates.checking); Spacer() }
            Text("Updates are downloaded as a DMG. This preview does not silently replace or restart your app or running processes.").font(.system(size: 11)).foregroundStyle(Palette.muted)
        }.padding(24).frame(width: 520).background(Palette.panel)
            .task { await updates.check() }
    }
}
