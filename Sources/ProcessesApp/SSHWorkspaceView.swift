import SwiftUI
import AppKit
import ProcessesProtocol

struct SSHWorkspaceView: View {
    let onRunCommand: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var hosts: [SSHHost] = []
    @State private var selectedID: String?
    @State private var editing: SSHHost?
    @State private var showingEditor = false
    @State private var deleting = false
    @State private var failure: String?
    @State private var notice: String?
    @State private var remotePath = "."
    @State private var entries: [SFTPEntry] = []
    @State private var listingLoaded = false
    @State private var busy = false
    @State private var generation = UUID()
    private var selected: SSHHost? { hosts.first { $0.id == selectedID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Remote workspace").font(.system(size: 21, weight: .semibold))
                    Text("SSH hosts, local keys and secure file transfers.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            HStack(spacing: 0) {
                hostSidebar
                Divider()
                VStack(alignment: .leading, spacing: 16) {
                    if let host = selected {
                        hostDetails(host)
                        Divider()
                        fileBrowser(host)
                    } else {
                        Spacer()
                        VStack(spacing: 12) {
                            Image(systemName: "network").font(.system(size: 34)).foregroundStyle(Palette.mint)
                            Text("Your remote hosts").font(.system(size: 18, weight: .semibold))
                            Text("Save a host to open an SSH terminal and browse its files.").font(.system(size: 12)).foregroundStyle(Palette.muted)
                            Button("Add Host") { addHost() }
                        }.frame(maxWidth: .infinity)
                        Spacer()
                    }
                    if let failure { Label(failure, systemImage: "exclamationmark.circle").foregroundStyle(.orange).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                    if let notice { Text(notice).font(.system(size: 12)).foregroundStyle(Palette.mint).fixedSize(horizontal: false, vertical: true) }
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(width: 900, height: 600).background(Palette.panel)
        .onAppear(perform: loadHosts)
        .sheet(isPresented: $showingEditor) {
            SSHHostEditor(host: editing) { host in
                var updated = hosts
                if let index = updated.firstIndex(where: { $0.id == host.id }) { updated[index] = host }
                else { updated.append(host) }
                do { try SSHHostStore.save(updated); hosts = updated; select(host); showingEditor = false }
                catch { throw error }
            }
        }
        .alert("Remove saved host?", isPresented: $deleting) {
            Button("Cancel", role: .cancel) { }
            Button("Remove", role: .destructive) { removeHost() }
        } message: { Text("This removes the RunDock host entry. Keys and remote files are kept.") }
    }

    private var hostSidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("HOSTS").font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(Palette.muted)
                Spacer()
                Button(action: addHost) { Image(systemName: "plus") }.buttonStyle(.plain).help("Add host").accessibilityLabel("Add host")
            }.padding(.horizontal, 12).padding(.top, 18)
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(hosts) { host in
                        Button { select(host) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "server.rack").foregroundStyle(selectedID == host.id ? Palette.mint : Palette.muted)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(host.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text(host.host).font(.system(size: 10)).foregroundStyle(Palette.muted).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }.padding(12).background(selectedID == host.id ? Color.white.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 8)
            }
            Text("Keys stay on this Mac. Passwords and passphrases are entered in the terminal.").font(.system(size: 11)).foregroundStyle(Palette.muted).padding(14)
        }.frame(width: 220).background(Palette.sidebar)
    }

    private func hostDetails(_ host: SSHHost) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(host.name).font(.system(size: 20, weight: .semibold)).lineLimit(1)
                    Text("\(host.user)@\(host.host) · port \(host.port)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Palette.muted).textSelection(.enabled)
                }
                Spacer()
                Button("Edit") { editing = host; showingEditor = true }.disabled(busy)
                Button { deleting = true } label: { Image(systemName: "trash") }.help("Remove saved host").disabled(busy)
            }
            if let key = host.keyPath, !key.isEmpty {
                HStack {
                    Label((key as NSString).lastPathComponent, systemImage: "key").font(.system(size: 11)).foregroundStyle(Palette.muted).help(key)
                    Button("Load Key into Agent") { runKey(host) }.font(.system(size: 11))
                }
            }
            HStack {
                Button { connect(host) } label: { Label("Connect Terminal", systemImage: "terminal") }.buttonStyle(MintButtonStyle())
                Text("OpenSSH verifies the host and prompts in your terminal.").font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
        }
    }

    private func fileBrowser(_ host: SSHHost) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Files").font(.system(size: 15, weight: .semibold))
                Text("SFTP").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.mint)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Upload…") { upload(host) }.disabled(busy || !listingLoaded)
            }
            HStack(spacing: 8) {
                Button { remotePath = parentPath(remotePath); refresh(host) } label: { Image(systemName: "arrow.up") }.help("Parent directory").disabled(busy)
                TextField("Remote path", text: $remotePath).font(.system(size: 12, design: .monospaced)).textFieldStyle(.roundedBorder).onSubmit { refresh(host) }.disabled(busy)
                Button(listingLoaded ? "Refresh" : "Browse") { refresh(host) }.disabled(busy)
            }
            if listingLoaded {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if entries.isEmpty { Text("This directory is empty.").font(.system(size: 12)).foregroundStyle(Palette.muted).padding(24) }
                        ForEach(entries, id: \.path) { entry in
                            HStack(spacing: 10) {
                                Image(systemName: entry.isDirectory ? "folder.fill" : "doc").foregroundStyle(entry.isDirectory ? Palette.mint : Palette.muted).frame(width: 18)
                                Button(entry.name) {
                                    if entry.isDirectory { remotePath = entry.path; refresh(host) }
                                    else { download(entry, host) }
                                }.buttonStyle(.plain).font(.system(size: 12)).lineLimit(1).help(entry.isDirectory ? "Open directory" : "Download file")
                                Spacer()
                                if let size = entry.size, !entry.isDirectory { Text(ByteCountFormatter.string(fromByteCount: Int64(clamping: size), countStyle: .file)).font(.system(size: 10)).foregroundStyle(Palette.muted) }
                                if !entry.isDirectory {
                                    Button { download(entry, host) } label: { Image(systemName: "arrow.down.to.line") }.buttonStyle(.plain).help("Download \(entry.name)")
                                }
                            }.padding(.horizontal, 12).padding(.vertical, 10)
                            Divider().opacity(0.4)
                        }
                    }
                }.background(Palette.shell, in: RoundedRectangle(cornerRadius: 7)).disabled(busy)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "folder.badge.gearshape").font(.system(size: 28)).foregroundStyle(Palette.muted)
                    Text("Connect in the terminal first").font(.system(size: 13, weight: .medium))
                    Text("Accept the host key and authenticate using SSH. SFTP then uses your known hosts and SSH agent without interactive password prompts.").font(.system(size: 12)).foregroundStyle(Palette.muted).multilineTextAlignment(.center).frame(maxWidth: 360)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(20).background(Palette.shell, in: RoundedRectangle(cornerRadius: 7))
            }
        }.frame(maxHeight: .infinity)
    }

    private func loadHosts() {
        do { hosts = try SSHHostStore.load(); if let first = hosts.first { select(first) } }
        catch { failure = error.localizedDescription }
    }
    private func select(_ host: SSHHost) {
        selectedID = host.id; remotePath = "."; entries = []; listingLoaded = false; failure = nil; notice = nil; generation = UUID()
    }
    private func addHost() { editing = nil; showingEditor = true }
    private func removeHost() {
        guard let host = selected else { return }
        let updated = hosts.filter { $0.id != host.id }
        do { try SSHHostStore.save(updated); hosts = updated; selectedID = nil; entries = []; listingLoaded = false; if let first = hosts.first { select(first) } }
        catch { failure = error.localizedDescription }
    }
    private func connect(_ host: SSHHost) {
        do { onRunCommand(host.name, try host.terminalCommand()); dismiss() }
        catch { failure = error.localizedDescription }
    }
    private func runKey(_ host: SSHHost) {
        do { if let command = try host.keyAgentCommand() { onRunCommand("Load key · \(host.name)", command); dismiss() } }
        catch { failure = error.localizedDescription }
    }
    private func parentPath(_ path: String) -> String {
        if path == "/" { return "/" }
        if path == "." { return ".." }
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "." : parent
    }
    private func refresh(_ host: SSHHost) {
        guard !busy else { return }
        busy = true; failure = nil; notice = nil
        let request = generation, path = remotePath
        Task {
            do {
                let result = try await SFTPClient(host: host).list(path: path)
                if generation == request { entries = result.sorted { $0.isDirectory == $1.isDirectory ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.isDirectory }; listingLoaded = true }
            } catch { if generation == request { failure = "SFTP: \(error.localizedDescription)" } }
            busy = false
        }
    }
    private func download(_ entry: SFTPEntry, _ host: SSHHost) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = entry.name; panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        transfer(host) { try await SFTPClient(host: host).download(remotePath: entry.path, localURL: url) } success: { "Downloaded \(entry.name)." }
    }
    private func upload(_ host: SSHHost) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = (remotePath as NSString).appendingPathComponent(url.lastPathComponent)
        let alert = NSAlert()
        alert.messageText = "Upload to \(host.name)?"
        alert.informativeText = "Destination: \(path)\nAn existing file at this path will be replaced."
        alert.addButton(withTitle: "Upload"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        transfer(host) { try await SFTPClient(host: host).upload(localURL: url, remotePath: path) } success: { "Uploaded \(url.lastPathComponent). Refresh to see the file." }
    }
    private func transfer(_ host: SSHHost, operation: @escaping () async throws -> Void, success: @escaping () -> String) {
        guard !busy else { return }
        busy = true; failure = nil; notice = nil
        let request = generation
        Task {
            do { try await operation(); if generation == request { notice = success() } }
            catch { if generation == request { failure = "SFTP: \(error.localizedDescription)" } }
            busy = false
        }
    }
}

private struct SSHHostEditor: View {
    let host: SSHHost?
    let onSave: (SSHHost) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var hostname = ""
    @State private var user = ""
    @State private var port = "22"
    @State private var keyPath = ""
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(host == nil ? "Add SSH host" : "Edit SSH host").font(.system(size: 20, weight: .semibold))
            Form {
                TextField("Name", text: $name)
                TextField("Hostname", text: $hostname)
                TextField("Username", text: $user)
                TextField("Port", text: $port)
                HStack {
                    TextField("Private key path (optional)", text: $keyPath)
                    Button("Choose…", action: chooseKey)
                }
            }.textFieldStyle(.roundedBorder)
            Text("RunDock saves the key file's path only. OpenSSH reads it when you connect; passphrases stay in your terminal.").font(.system(size: 11)).foregroundStyle(Palette.muted)
            if let failure { Text(failure).font(.system(size: 12)).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save Host", action: save).keyboardShortcut(.defaultAction)
            }
        }.padding(26).frame(width: 510).background(Palette.panel)
            .onAppear { if let host { name = host.name; hostname = host.host; user = host.user; port = String(host.port); keyPath = host.keyPath ?? "" } }
    }
    private func chooseKey() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.message = "Choose an existing private key file. Its contents are not imported."
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if panel.runModal() == .OK, let url = panel.url { keyPath = url.path }
    }
    private func save() {
        guard let number = Int(port), (1...65535).contains(number) else { failure = "Enter a port from 1 to 65535."; return }
        let cleanKey = keyPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = SSHHost(id: host?.id ?? UUID().uuidString, name: name.trimmingCharacters(in: .whitespacesAndNewlines), host: hostname.trimmingCharacters(in: .whitespacesAndNewlines), user: user.trimmingCharacters(in: .whitespacesAndNewlines), port: number, keyPath: cleanKey.isEmpty ? nil : cleanKey, group: host?.group)
        do { try result.validate(); try onSave(result) }
        catch { failure = error.localizedDescription }
    }
}
