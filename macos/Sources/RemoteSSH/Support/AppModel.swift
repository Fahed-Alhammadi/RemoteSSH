import AppKit
import Foundation
import Observation
import RemoteSSHCore
import UniformTypeIdentifiers

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
}

/// Root UI state. Browsing, local file operations and transfers live in extensions
/// (`AppModel+Remote`, `AppModel+Local`) and in `TransferManager`.
@MainActor
@Observable
final class AppModel {
    // Persistence
    @ObservationIgnored let siteStore = SiteStore()
    @ObservationIgnored let knownHosts = KnownHostsStore()

    var settings = AppSettings.load() {
        didSet { if settings != oldValue { settings.save() } }
    }
    var sites: [Site] = []
    /// Quickconnect sites live only in memory.
    var transientSites: [UUID: Site] = [:]
    @ObservationIgnored var transientPasswords: [UUID: String] = [:]

    let prompts = PromptCenter()
    private(set) var log: [LogLine] = []
    @ObservationIgnored private lazy var logBuffer = LogBuffer { [weak self] lines in self?.append(lines) }

    // Remote browser
    var connection: ConnectionState = .disconnected
    var currentSite: Site?
    @ObservationIgnored var session: RemoteSession?
    var remotePath = ""
    var remoteEntries: [FileEntry] = []
    var remoteBusy = false

    // Local browser
    var localPath = FileManager.default.homeDirectoryForCurrentUser.path
    var localEntries: [FileEntry] = []

    // View options
    var showLog = true
    var showQueue = true
    var compareDirectories = false
    var synchronizedBrowsing = false
    @ObservationIgnored var syncBase: (local: String, remote: String)?

    var showSiteManager = false

    @ObservationIgnored lazy var transfers = TransferManager(model: self)
    @ObservationIgnored lazy var editWatcher = EditWatcher(model: self)

    init() {
        sites = siteStore.load()
        refreshLocal()
    }

    // MARK: Logging

    private static let logLimit = 5000

    /// Engine log lines arrive from background threads; they are batched and applied on the
    /// main actor once per run-loop turn instead of one task hop per line.
    func makeLogSink() -> LogSink {
        logBuffer.sink
    }

    private func append(_ lines: [LogLine]) {
        log.append(contentsOf: lines.lazy.filter { $0.kind != .trace })
        // Trim in chunks so a busy log doesn't shift 5000 elements on every line.
        if log.count > Self.logLimit + 500 { log.removeFirst(log.count - Self.logLimit) }
    }

    func clearLog() { log.removeAll() }
    func status(_ text: String) { append([LogLine(.status, text)]) }
    func error(_ text: String) { append([LogLine(.error, text)]) }

    // MARK: Sites

    func saveSites() {
        do { try siteStore.save(sites) } catch { self.error("Could not save sites: \(error.localizedDescription)") }
    }

    func site(for id: UUID) -> Site? {
        sites.first { $0.id == id } ?? transientSites[id] ?? (currentSite?.id == id ? currentSite : nil)
    }

    func password(for site: Site) -> String? {
        transientPasswords[site.id] ?? Keychain.password(for: site.id)
    }

    static let archiveType = UTType(filenameExtension: SiteArchive.fileExtension, conformingTo: .json) ?? .json

    /// File → Import from RemoteSSH…
    func importSites() {
        let panel = NSOpenPanel()
        panel.title = "Import from RemoteSSH"
        panel.allowedContentTypes = [Self.archiveType, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try SiteArchive.decode(Data(contentsOf: url)).importable()
            for site in imported.sites {
                sites.append(site)
                if let pw = imported.passwords[site.id] { Keychain.setPassword(pw, for: site.id) }
            }
            saveSites()
            status("Imported \(imported.sites.count) site\(imported.sites.count == 1 ? "" : "s") from \(url.lastPathComponent)")
        } catch {
            self.error("Import failed: \(error.localizedDescription)")
        }
    }

    /// File → Export Sites…
    func exportSites() {
        guard !sites.isEmpty else { error("There are no saved sites to export."); return }
        let alert = NSAlert()
        alert.messageText = "Include passwords in the export?"
        alert.informativeText = "Passwords are written in plain text. Only include them if you will keep the file somewhere safe."
        alert.addButton(withTitle: "Export Without Passwords")
        alert.addButton(withTitle: "Include Passwords")
        alert.addButton(withTitle: "Cancel")
        let choice = alert.runModal()
        guard choice != .alertThirdButtonReturn else { return }

        let panel = NSSavePanel()
        panel.title = "Export Sites"
        panel.allowedContentTypes = [Self.archiveType]
        panel.nameFieldStringValue = "Sites.\(SiteArchive.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var passwords: [UUID: String]?
        if choice == .alertSecondButtonReturn {
            passwords = Dictionary(uniqueKeysWithValues: sites.compactMap { s in Keychain.password(for: s.id).map { (s.id, $0) } })
        }
        do {
            try SiteArchive(sites: sites, passwords: passwords).encoded().write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            status("Exported \(sites.count) sites to \(url.lastPathComponent)")
        } catch {
            self.error("Export failed: \(error.localizedDescription)")
        }
    }

    // MARK: Transfers

    func download(_ entries: [FileEntry]) {
        guard let site = currentSite else { return }
        transfers.enqueueDownload(entries: entries, remoteDir: remotePath, localDir: localPath, site: site)
    }

    func upload(_ entries: [FileEntry]) {
        upload(paths: entries.map { localURL($0.name).path })
    }

    func upload(paths: [String]) {
        guard let site = currentSite, connection == .connected else { error("Not connected to any server"); return }
        transfers.enqueueUpload(localPaths: paths, remoteDir: remotePath, site: site)
    }

    func comparison(forRemote remote: Bool) -> [String: DirectoryComparison.State] {
        guard compareDirectories, connection == .connected else { return [:] }
        return remote ? DirectoryComparison.compare(remoteEntries, with: localEntries)
                      : DirectoryComparison.compare(localEntries, with: remoteEntries)
    }
}

/// Collects log lines from any thread and delivers them to the main actor in batches.
final class LogBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [LogLine] = []
    private var scheduled = false
    private let deliver: @MainActor ([LogLine]) -> Void

    init(deliver: @escaping @MainActor ([LogLine]) -> Void) {
        self.deliver = deliver
    }

    var sink: LogSink {
        { [weak self] line in self?.add(line) }
    }

    private func add(_ line: LogLine) {
        lock.lock()
        pending.append(line)
        let needsFlush = !scheduled
        scheduled = true
        lock.unlock()
        guard needsFlush else { return }
        Task { @MainActor [weak self] in self?.flush() }
    }

    @MainActor private func flush() {
        lock.lock()
        let lines = pending
        pending.removeAll(keepingCapacity: true)
        scheduled = false
        lock.unlock()
        deliver(lines)
    }
}
