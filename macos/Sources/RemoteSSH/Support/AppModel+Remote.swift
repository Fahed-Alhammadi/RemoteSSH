import AppKit
import Foundation
import RemoteSSHCore

/// Connection handling and remote-pane operations.
extension AppModel {
    // MARK: Connection

    func quickConnect(host: String, user: String, password: String, port: String) {
        do {
            let input = try QuickConnectInput.parse(host: host, user: user, password: password, port: port)
            transientSites[input.site.id] = input.site
            transientPasswords[input.site.id] = input.password
            connect(to: input.site, initialPath: input.initialPath)
        } catch {
            self.error(error.localizedDescription)
        }
    }

    func connect(to site: Site, initialPath: String? = nil) {
        Task { await connectAsync(site, initialPath: initialPath) }
    }

    private func connectAsync(_ site: Site, initialPath: String?) async {
        await disconnect()
        var pass = password(for: site) ?? ""
        if site.logonType == .askForPassword && transientPasswords[site.id] == nil {
            guard let entered = await prompts.requestPassword(prompt: "Please enter the password for \(site.effectiveUser)@\(site.host)") else { return }
            pass = entered
            transientPasswords[site.id] = entered
        }
        let session = makeSession(for: site, password: pass)
        currentSite = site
        connection = .connecting
        do {
            try await session.connect()
            self.session = session
            connection = .connected
            let start: String
            if let initialPath, !initialPath.isEmpty { start = initialPath }
            else if !site.defaultRemoteDirectory.isEmpty { start = site.defaultRemoteDirectory }
            else { start = try await session.homeDirectory() }
            if !site.defaultLocalDirectory.isEmpty { navigateLocal(to: site.defaultLocalDirectory) }
            await navigateRemote(to: start)
            transfers.resume()
        } catch {
            connection = .disconnected
            self.error(error.localizedDescription)
            status("Could not connect to server")
        }
    }

    func makeSession(for site: Site, password: String) -> RemoteSession {
        SessionFactory.make(
            site: site,
            credentials: SessionCredentials(password: password),
            options: settings.sessionOptions,
            prompter: prompts,
            hostKeys: knownHosts,
            log: makeLogSink()
        )
    }

    func disconnect() async {
        if let session { await session.disconnect() }
        session = nil
        connection = .disconnected
        remoteEntries = []
        remotePath = ""
    }

    func reconnect() {
        guard let site = currentSite else { return }
        connect(to: site, initialPath: remotePath)
    }

    // MARK: Browsing

    func navigateRemote(to path: String) async {
        guard let session else { return }
        remoteBusy = true
        defer { remoteBusy = false }
        do {
            let entries = try await session.list(path)
            if synchronizedBrowsing, let base = syncBase, path.hasPrefix(base.remote) {
                let local = base.local + path.dropFirst(base.remote.count)
                if FileManager.default.fileExists(atPath: local) { navigateLocal(to: local, sync: false) }
            }
            remotePath = path
            remoteEntries = entries
        } catch {
            self.error(error.localizedDescription)
            if case RemoteSSHError.connectionFailed = error { connection = .disconnected }
        }
    }

    func refreshRemote() {
        Task { await navigateRemote(to: remotePath) }
    }

    func toggleSynchronizedBrowsing() {
        synchronizedBrowsing.toggle()
        syncBase = synchronizedBrowsing ? (localPath, remotePath) : nil
        status(synchronizedBrowsing ? "Synchronized browsing enabled" : "Synchronized browsing disabled")
    }

    // MARK: Operations

    /// Runs a remote operation in the current directory and refreshes the listing afterwards.
    private func remoteOperation(_ body: @escaping (RemoteSession, String) async throws -> Void) {
        guard let session else { return }
        let base = remotePath
        Task {
            do { try await body(session, base) } catch { self.error(error.localizedDescription) }
            await navigateRemote(to: base)
        }
    }

    func remoteMakeDirectory(enter: Bool = false) {
        Task {
            guard let name = await prompts.requestText(title: "Create Directory", message: "Name of the new directory:", initial: "New directory"),
                  !name.isEmpty, let session else { return }
            let path = RemotePath.join(remotePath, name)
            do {
                try await session.makeDirectory(path)
                await navigateRemote(to: enter ? path : remotePath)
            } catch { self.error(error.localizedDescription) }
        }
    }

    func remoteRename(_ entry: FileEntry) {
        Task {
            guard let name = await prompts.requestText(title: "Rename", message: "New name for \(entry.name):", initial: entry.name),
                  !name.isEmpty, name != entry.name else { return }
            remoteOperation { session, base in
                try await session.rename(RemotePath.join(base, entry.name), to: RemotePath.join(base, name))
            }
        }
    }

    func remoteDelete(_ entries: [FileEntry]) {
        guard !entries.isEmpty, confirm("Delete \(Self.describe(entries)) from the server?", button: "Delete") else { return }
        remoteOperation { session, base in
            for entry in entries {
                try await Self.deleteRecursive(session, RemotePath.join(base, entry.name), isDirectory: entry.isDirectory && !entry.isLink)
            }
        }
    }

    private static func deleteRecursive(_ session: RemoteSession, _ path: String, isDirectory: Bool) async throws {
        guard isDirectory else { try await session.deleteFile(path); return }
        for child in try await session.list(path) {
            try await deleteRecursive(session, RemotePath.join(path, child.name), isDirectory: child.isDirectory && !child.isLink)
        }
        try await session.removeDirectory(path)
    }

    func remoteChmod(_ entries: [FileEntry], mode: Int) {
        remoteOperation { session, base in
            for entry in entries { try await session.chmod(RemotePath.join(base, entry.name), mode: mode) }
        }
    }

    func customCommand() {
        Task {
            guard let cmd = await prompts.requestText(title: "Custom Command", message: "Raw FTP command to send to the server:", initial: ""),
                  !cmd.isEmpty else { return }
            remoteOperation { session, _ in
                self.status(try await session.rawCommand(cmd))
            }
        }
    }

    func copyURLs(_ entries: [FileEntry]) {
        guard let site = currentSite else { return }
        let urls = entries.map { site.displayAddress + RemotePath.join(remotePath, $0.name) }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urls.joined(separator: "\n"), forType: .string)
    }

    /// View/Edit: download to a temp folder, open with the default app, offer upload on save.
    func viewEdit(_ entry: FileEntry) {
        guard let site = currentSite, let session else { return }
        let remote = RemotePath.join(remotePath, entry.name)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteSSH-edit/\(UUID().uuidString)", isDirectory: true)
        let local = dir.appendingPathComponent(entry.name)
        Task {
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try await session.download(remote, to: local, resumeFrom: 0, cancel: CancelToken(), progress: { _ in })
                editWatcher.watch(local: local, remote: remote, siteID: site.id)
                NSWorkspace.shared.open(local)
            } catch { self.error(error.localizedDescription) }
        }
    }

    // MARK: Helpers

    static func describe(_ entries: [FileEntry]) -> String {
        entries.count == 1 ? "\"\(entries[0].name)\"" : "\(entries.count) items"
    }

    func confirm(_ message: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
