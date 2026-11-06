import SwiftUI
import AppKit
import ProcessesProtocol

struct AIClientIcon: View {
    let clientID: String
    var size: CGFloat = 28

    static func clientID(for actor: String, version: String? = nil) -> String? {
        let name = actor.lowercased()
        if name.contains("codex") { return "codex" }
        if name.contains("claude-code") || name.contains("claude code") { return "claude-code" }
        if name.contains("claude") { return "claude-desktop" }
        if name.contains("cursor") { return "cursor" }
        if name.contains("gemini") { return "gemini-cli" }
        if name.contains("windsurf") { return "windsurf" }
        if name.contains("opencode") {
            let major = version?.trimmingCharacters(in: CharacterSet(charactersIn: "v")).split(separator: ".").first.flatMap { Int($0) }
            return name.contains("v2") || (major ?? 0) >= 2 ? "opencode-v2" : "opencode"
        }
        if name.contains("visual studio") || name.contains("vscode") { return "vscode" }
        if name.contains("chatgpt") { return "chatgpt-desktop" }
        return nil
    }

    private var image: NSImage? {
        let appNames: [String]
        switch clientID {
        case "codex": appNames = ["Codex"]
        case "chatgpt", "chatgpt-desktop": appNames = ["ChatGPT"]
        case "claude-code", "claude-desktop": appNames = ["Claude"]
        case "cursor": appNames = ["Cursor"]
        case "vscode": appNames = ["Visual Studio Code"]
        case "windsurf": appNames = ["Windsurf", "Devin"]
        case "opencode", "opencode-v2": appNames = ["OpenCode", "opencode"]
        default: appNames = []
        }
        if clientID == "codex", let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        for name in appNames {
            for directory in ["/Applications", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path] {
                let path = "\(directory)/\(name).app"
                if FileManager.default.fileExists(atPath: path) { return NSWorkspace.shared.icon(forFile: path) }
            }
        }
        if let folder = Bundle.main.resourceURL?.appendingPathComponent("ai-icons"),
           let image = NSImage(contentsOf: folder.appendingPathComponent("\(clientID).png")) { return image }
        return nil
    }

    var body: some View {
        Group {
            if let image { Image(nsImage: image).resizable().interpolation(.high).scaledToFit() }
            else { Image(systemName: clientID == "chatgpt" ? "globe" : "terminal").resizable().scaledToFit().padding(5).foregroundStyle(Palette.muted) }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct AIConnectionsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected = "codex"
    @State private var notice: String?
    @State private var failure: String?
    @State private var installing = false
    @State private var configured = Set(UserDefaults.standard.stringArray(forKey: "configuredAIClients") ?? [])
    private var client: AIConnector { AIConnectors.clients.first { $0.id == selected } ?? AIConnectors.clients[0] }
    private var helper: URL { AppModel.helperURL().resolvingSymlinksInPath() }
    private var configuration: String { AIConnectors.configuration(for: client, executableURL: helper) }
    private var automatic: Bool { ["json", "json-vscode"].contains(client.kind) }
    private var cliAvailable: Bool { AIConnectors.cliExecutable(for: client) != nil }
    private var remoteOnly: Bool { client.kind == "manual-remote" }
    private var skillURL: URL? { Bundle.main.resourceURL?.appendingPathComponent("skills/rundock/SKILL.md") }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Connect your AI").font(.system(size: 21, weight: .semibold))
                    Text("One shared place for the commands your AI runs.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            HStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(AIConnectors.clients) { item in
                            Button {
                                selected = item.id; notice = nil; failure = nil
                            } label: {
                                HStack(spacing: 10) {
                                    AIClientIcon(clientID: item.id)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title).font(.system(size: 12, weight: selected == item.id ? .semibold : .regular)).lineLimit(2)
                                        HStack(spacing: 4) {
                                            Circle().fill(connected(item.id) ? Palette.mint : Color.gray).frame(width: 4, height: 4)
                                            Text(connectionLabel(item.id)).font(.system(size: 10)).foregroundStyle(Palette.muted)
                                        }
                                    }.fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 0)
                                }.padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(selected == item.id ? Color.white.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 7))
                            }.buttonStyle(.plain).accessibilityLabel(item.title)
                        }
                    }.padding(10)
                }.frame(width: 215).background(Palette.sidebar)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 12) {
                            AIClientIcon(clientID: client.id, size: 40)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(client.title).font(.system(size: 18, weight: .semibold))
                                Text(remoteOnly ? "Remote transport required" : "Local MCP · STDIO").font(.system(size: 11)).foregroundStyle(remoteOnly ? .orange : Palette.mint)
                            }
                        }
                        Text(instructions).font(.system(size: 12)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                        if let connection = connections(client.id).max(by: { $0.lastSeen < $1.lastSeen }) {
                            HStack(spacing: 7) {
                                Circle().fill(connection.isConnected ? Palette.mint : Color.gray).frame(width: 6, height: 6)
                                Text(connection.isConnected ? "MCP session connected" : "MCP session disconnected").font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text(connection.lastSeen, style: .relative).font(.system(size: 11)).foregroundStyle(Palette.muted)
                            }
                            Text("Client: \(connection.clientName)\(connection.clientVersion.map { " · " + $0 } ?? "")").font(.system(size: 11)).foregroundStyle(Palette.muted)
                            if let lastUsed = connection.lastUsedAt {
                                HStack { Text("Last tool call"); Spacer(); Text(lastUsed, style: .relative) }.font(.system(size: 11)).foregroundStyle(Palette.muted)
                            }
                        }
                        if !remoteOnly {
                            HStack(spacing: 10) {
                                if automatic || cliAvailable {
                                    Button(installing ? "Connecting…" : "Connect \(client.title)") { installConfiguration() }.buttonStyle(MintButtonStyle()).disabled(installing)
                                }
                            }
                            if automatic, let path = client.configPath {
                                Text("Saves the RunDock server in ~/\(path). Existing settings are preserved and backed up.")
                                    .font(.system(size: 11)).foregroundStyle(Palette.muted).textSelection(.enabled)
                            }
                            DisclosureGroup("Manual configuration") {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(configuration).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                                        .background(Palette.shell, in: RoundedRectangle(cornerRadius: 7))
                                    Button("Copy Configuration") { copyConfiguration() }
                                }.padding(.top, 10)
                            }.font(.system(size: 12)).id(client.id)
                        }
                        if client.id == "codex" {
                            Divider()
                            Text("Automatic command routing").font(.system(size: 13, weight: .semibold))
                            Text("Connect Codex installs both the MCP server and RunDock routing skill in one step. Start a new chat afterward so the client loads them.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                            if !cliAvailable { Button("Install Codex Skill") { installSkill() }.disabled(installing) }
                            Text(AIIntegration.codexSkillURL().path).font(.system(size: 10, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled)
                        }
                        if let notice { Label(notice, systemImage: "checkmark.circle").font(.system(size: 12)).foregroundStyle(Palette.mint).fixedSize(horizontal: false, vertical: true) }
                        if let failure { Label(failure, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
                        if let url = URL(string: client.documentationURL) { Link("Setup documentation ↗", destination: url).font(.system(size: 12)) }
                        Divider()
                        Text("A green status means a real MCP client session is sending heartbeats. Setup saved means the client has not connected yet. Ask your AI to run a command through RunDock to confirm tool use; jobs appear with live output, ports and results.")
                            .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                    }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxWidth: .infinity)
            }
        }.frame(width: 840, height: 600).background(Palette.panel)
    }

    private var instructions: String {
        switch client.kind {
        case "json", "json-vscode": return "Configure this client once, then restart or refresh its MCP servers. Its AI can start, stop and inspect RunDock jobs across projects."
        case "skill-and-manual-mcp": return cliAvailable ? "Connect once to install RunDock's MCP server and routing skill. Start a new Codex chat afterward; no project forms or configuration editing are needed." : "The Codex CLI was not found. Install Codex or use the manual configuration below."
        case "manual-cli": return cliAvailable ? "Connect once to install RunDock at user scope. Refresh the client and approve the RunDock tools when asked." : "This client's CLI was not found. Install it or use the manual configuration below."
        case "manual-stdio": return "In ChatGPT desktop, open Settings → MCP servers → Add server and choose STDIO. Enter this command and argument separately. Availability depends on your desktop version and workspace."
        case "manual-versioned": return "Use the configuration for this exact OpenCode major version. Its MCP schema differs between v1 and v2; add the fragment to your existing configuration."
        case "manual-json": return "Open this client's MCP settings and use the standard STDIO configuration below. Check its current configuration format before saving. Automatic configuration is not enabled for this client."
        case "manual-remote": return "ChatGPT web requires a reachable HTTPS MCP endpoint. This RunDock build provides a local STDIO server; a secure remote bridge is still required for web access."
        default: return "Any AI client supporting local MCP over STDIO can use this command and argument. Configure it in the client's own MCP settings. The AI model can be from any provider."
        }
    }

    private func copyConfiguration() {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(configuration, forType: .string)
        notice = "Configuration copied."; failure = nil
    }
    private func connections(_ clientID: String) -> [AIConnection] {
        model.aiConnections.filter {
            AIClientIcon.clientID(for: $0.clientName, version: $0.clientVersion) == clientID || (clientID == "generic-mcp" && AIClientIcon.clientID(for: $0.clientName, version: $0.clientVersion) == nil)
        }
    }
    private func connected(_ clientID: String) -> Bool { connections(clientID).contains { $0.isConnected } }
    private func connectionLabel(_ clientID: String) -> String {
        if connected(clientID) { return "Connected" }
        if !connections(clientID).isEmpty { return "Disconnected" }
        return configured.contains(clientID) ? "Setup saved · waiting" : "Not connected"
    }
    private func installConfiguration() {
        installing = true; failure = nil; notice = nil
        let target = client, executable = helper, bundledSkill = skillURL
        Task {
            do {
                _ = try await Task.detached { try AIConnectors.verifyMCP(executableURL: executable) }.value
                if automatic {
                    let url = try await Task.detached { try AIConnectors.install(for: target, executableURL: executable) }.value
                    notice = "MCP installed and local server verified. Refresh \(target.title)'s MCP servers to load it. Saved to \(url.path)."
                } else {
                    try await Task.detached { try AIConnectors.installCLI(for: target, executableURL: executable) }.value
                    if target.id == "codex" {
                        guard let bundledSkill else { throw RuntimeError("MCP installed, but the bundled routing skill is unavailable.") }
                        do { _ = try AIIntegration.installCodexSkill(from: bundledSkill) }
                        catch { throw RuntimeError("MCP installed and verified, but the routing skill needs attention: \(error.localizedDescription)") }
                    }
                    notice = "MCP installed and local server verified\(target.id == "codex" ? ", including the routing skill" : ""). Start a new chat or refresh \(target.title)'s MCP servers."
                }
                configured.insert(target.id)
                UserDefaults.standard.set(Array(configured).sorted(), forKey: "configuredAIClients")
            } catch { failure = error.localizedDescription }
            installing = false
        }
    }
    private func installSkill() {
        guard let source = skillURL else { failure = "Bundled skill is unavailable."; return }
        do {
            let url = try AIIntegration.installCodexSkill(from: source)
            notice = "Skill installed at \(url.path). Start a new Codex chat to load it."; failure = nil
        } catch { failure = error.localizedDescription }
    }
}
