import RemoteSSHCore
import Foundation
import Observation

/// Runs the transfer queue with up to `maxConcurrentTransfers` workers, each on its own
/// connection. Pending items persist in SQLite.
@MainActor
@Observable
final class TransferManager {
    @ObservationIgnored private unowned let model: AppModel
    @ObservationIgnored private let store = QueueStore()

    var items: [TransferItem] = []
    var processing = true
    /// Bytes/second per active item.
    var speeds: [UUID: Double] = [:]

    @ObservationIgnored private var cancelTokens: [UUID: CancelToken] = [:]
    @ObservationIgnored private var idleSessions: [UUID: [RemoteSession]] = [:]
    /// Closes the pooled connections once the queue has been empty for a while.
    @ObservationIgnored private var idleTimer: Task<Void, Never>?
    private static let idleTimeout: Duration = .seconds(60)
    @ObservationIgnored private var retries: [UUID: Int] = [:]
    /// Items that already had their free retry after failing on a reused (possibly stale) pooled connection.
    @ObservationIgnored private var freshRetried: Set<UUID> = []
    /// Queued retries wait until this time (backoff) before they start again.
    @ObservationIgnored private var retryAt: [UUID: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var overwriteForAll: [TransferDirection: OverwriteAction] = [:]
    @ObservationIgnored private var saveScheduled = false
    @ObservationIgnored private var saveFailed = false
    /// Queue saves run here, in order, off the main thread.
    @ObservationIgnored private let saveQueue = DispatchQueue(label: "remotessh.queue-store", qos: .utility)
    /// Items that skip the "file exists" check (View/Edit re-uploads).
    @ObservationIgnored private var forceOverwrite: Set<UUID> = []
    /// Running items the user removed; they leave the list once their worker stops.
    @ObservationIgnored private var removeWhenStopped: Set<UUID> = []

    init(model: AppModel) {
        self.model = model
        items = store.load()
    }

    var queued: [TransferItem] { items.filter { $0.status == .queued || $0.status == .transferring } }
    var failed: [TransferItem] { items.filter { $0.status == .failed } }
    var finished: [TransferItem] { items.filter { $0.status == .finished } }
    var activeCount: Int { items.filter { $0.status == .transferring }.count }
    var queuedBytes: Int64 { queued.reduce(0) { $0 + ($1.size ?? 0) } }

    // MARK: Enqueue

    /// Folders are listed with the browse session as it was when the download was requested; when the
    /// connection changes (Disconnect, another site) adding stops.
    func enqueueDownload(entries: [FileEntry], remoteDir: String, localDir: String, site: Site) {
        let session = model.session
        Task {
            for entry in entries {
                let remote = RemotePath.join(remoteDir, entry.name)
                let local = (localDir as NSString).appendingPathComponent(entry.name)
                if entry.isDirectory {
                    guard let session, model.session === session else { break }
                    await expandRemoteDirectory(session, remote: remote, local: local, site: site)
                } else {
                    add(TransferItem(siteID: site.id, direction: .download, localPath: local, remotePath: remote, size: entry.size))
                }
            }
            if let session, model.session !== session { model.status("Stopped adding folder contents to the queue: the connection changed") }
            resume()
        }
    }

    private func expandRemoteDirectory(_ session: RemoteSession, remote: String, local: String, site: Site) async {
        guard model.session === session else { return }
        do {
            try FileManager.default.createDirectory(atPath: local, withIntermediateDirectories: true)
            for child in try await session.list(remote) {
                guard model.session === session else { return }
                let r = RemotePath.join(remote, child.name)
                let l = (local as NSString).appendingPathComponent(child.name)
                if child.isDirectory && child.isLink {
                    // Links to folders can loop (e.g. "up -> .."), which would recurse forever.
                    model.status("Skipped \(r): links to folders inside a folder are not followed")
                } else if child.isDirectory {
                    await expandRemoteDirectory(session, remote: r, local: l, site: site)
                } else {
                    add(TransferItem(siteID: site.id, direction: .download, localPath: l, remotePath: r, size: child.size))
                }
            }
        } catch {
            guard model.session === session else { return }
            model.error("Could not list \(remote): \(error.localizedDescription)")
        }
    }

    func enqueueUpload(localPaths: [String], remoteDir: String, site: Site) {
        let session = model.session
        Task {
            for path in localPaths {
                let remote = RemotePath.join(remoteDir, (path as NSString).lastPathComponent)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    guard let session, model.session === session else { break }
                    var visited: Set<String> = []
                    await expandLocalDirectory(session, local: path, remote: remote, site: site, visited: &visited)
                } else {
                    add(TransferItem(siteID: site.id, direction: .upload, localPath: path, remotePath: remote, size: LocalFileSystem.size(path)))
                }
            }
            if let session, model.session !== session { model.status("Stopped adding folder contents to the queue: the connection changed") }
            resume()
        }
    }

    /// `visited` holds the real paths of folders already expanded, so symbolic link loops end.
    private func expandLocalDirectory(_ session: RemoteSession, local: String, remote: String, site: Site, visited: inout Set<String>) async {
        guard model.session === session else { return }
        guard visited.insert(URL(fileURLWithPath: local).resolvingSymlinksInPath().path).inserted else {
            model.status("Skipped \(local): folder already included (symbolic link loop)")
            return
        }
        try? await session.makeDirectory(remote)  // may already exist
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: local) else { return }
        for name in children.sorted() {
            guard model.session === session else { return }
            let l = (local as NSString).appendingPathComponent(name)
            let r = RemotePath.join(remote, name)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: l, isDirectory: &isDir)
            if isDir.boolValue {
                await expandLocalDirectory(session, local: l, remote: r, site: site, visited: &visited)
            } else {
                add(TransferItem(siteID: site.id, direction: .upload, localPath: l, remotePath: r, size: LocalFileSystem.size(l)))
            }
        }
    }

    func enqueueSingleUpload(local: String, remote: String, site: Site, overwrite: Bool) {
        let item = TransferItem(siteID: site.id, direction: .upload, localPath: local, remotePath: remote, size: LocalFileSystem.size(local))
        if overwrite { forceOverwrite.insert(item.id) }
        add(item)
        resume()
    }

    private func add(_ item: TransferItem) {
        items.append(item)
        scheduleSave()
    }

    // MARK: Queue control

    func resume() {
        guard processing else { return }
        let free = model.settings.maxConcurrentTransfers - activeCount
        guard free > 0 else { return }
        let now = ContinuousClock.now
        let next = items.filter { $0.status == .queued && retryAt[$0.id].map { $0 <= now } ?? true }.prefix(free)
        for item in next {
            retryAt[item.id] = nil
            setStatus(item.id, .transferring)
            Task { await run(item.id) }
        }
    }

    func toggleProcessing() {
        processing.toggle()
        if processing { resume() }
    }

    /// Stops running transfers; waiting ones are marked as interrupted so they don't start later.
    func cancel(_ ids: Set<UUID>) {
        for id in ids {
            cancelTokens[id]?.cancel()
            retryAt[id] = nil
        }
        for item in items where ids.contains(item.id) && item.status == .queued {
            setStatus(item.id, .failed, error: RemoteSSHError.cancelled.localizedDescription)
        }
    }

    /// Closes the pooled connections that aren't transferring: on Disconnect, after sites were edited (so new
    /// transfers use the new settings), and once the queue has been empty for `idleTimeout`.
    func closeIdle() {
        idleTimer?.cancel()
        idleTimer = nil
        let pools = idleSessions.values.flatMap { $0 }
        idleSessions.removeAll()
        for session in pools { AppModel.close(session) }
    }

    private func scheduleIdleClose() {
        idleTimer?.cancel()
        guard !idleSessions.isEmpty else { return }
        idleTimer = Task { [weak self] in
            try? await Task.sleep(for: Self.idleTimeout)
            guard !Task.isCancelled, let self, self.queued.isEmpty else { return }
            self.closeIdle()
        }
    }

    func remove(_ ids: Set<UUID>) {
        cancel(ids)
        removeWhenStopped.formUnion(items.filter { ids.contains($0.id) && $0.status == .transferring }.map(\.id))
        items.removeAll { ids.contains($0.id) && $0.status != .transferring }
        scheduleSave()
    }

    func retry(_ ids: Set<UUID>) {
        for i in items.indices where ids.contains(items[i].id) && items[i].status == .failed {
            items[i].status = .queued
            items[i].error = nil
            items[i].transferred = 0
            retries[items[i].id] = nil
            freshRetried.remove(items[i].id)
        }
        scheduleSave()
        resume()
    }

    func clearFinished() {
        items.removeAll { $0.status == .finished }
    }

    func stopAll() {
        processing = false
        cancel(Set(items.filter { $0.status == .transferring }.map(\.id)))
    }

    // MARK: Worker

    private func index(_ id: UUID) -> Int? { items.firstIndex(where: { $0.id == id }) }

    private func setStatus(_ id: UUID, _ status: TransferStatus, error: String? = nil) {
        guard let i = index(id) else { return }
        items[i].status = status
        items[i].error = error
        if status == .finished { items[i].finishedAt = Date() }
        scheduleSave()
    }

    /// A pooled connection of the site (`reused`) or a new one.
    private func acquireSession(for site: Site) async throws -> (session: RemoteSession, reused: Bool) {
        if var pool = idleSessions[site.id], !pool.isEmpty {
            let s = pool.removeLast()
            idleSessions[site.id] = pool
            return (s, true)
        }
        let session = model.makeSession(for: site, password: model.password(for: site) ?? "")
        try await session.connect()
        model.noteConnected(session)
        return (session, false)
    }

    private func release(_ session: RemoteSession, siteID: UUID) {
        idleSessions[siteID, default: []].append(session)
    }

    private func run(_ id: UUID) async {
        guard let item = items.first(where: { $0.id == id }) else { return }
        guard let site = model.site(for: item.siteID) else {
            setStatus(id, .failed, error: "Site no longer exists")
            resume()
            return
        }
        let token = CancelToken()
        cancelTokens[id] = token
        defer {
            cancelTokens[id] = nil
            speeds[id] = nil
            if removeWhenStopped.remove(id) != nil {
                items.removeAll { $0.id == id }
                scheduleSave()
            }
            resume()
            if queued.isEmpty {
                // "Apply to all" answers last for one batch of transfers, not the rest of the session.
                overwriteForAll.removeAll()
                scheduleIdleClose()
            }
        }

        var session: RemoteSession?
        var reused = false
        do {
            let acquired = try await acquireSession(for: site)
            let s = acquired.session
            session = s
            reused = acquired.reused
            guard let offset = try await resolveConflict(item, session: s) else {
                setStatus(id, .finished, error: "Skipped")
                release(s, siteID: site.id)
                return
            }
            // "Rename file" changes the target path; transfer to the new name, not over the existing file.
            let target = items.first(where: { $0.id == id }) ?? item
            let started = Date()
            let throttle = ProgressThrottle()
            let progress: ProgressHandler = { [weak self] p in
                guard throttle.shouldEmit(p) else { return }
                Task { @MainActor in self?.update(id, progress: p, offset: offset, started: started) }
            }
            if target.direction == .download {
                try FileManager.default.createDirectory(atPath: (target.localPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try await s.download(target.remotePath, to: URL(fileURLWithPath: target.localPath), resumeFrom: offset, cancel: token, progress: progress)
            } else {
                try await s.upload(URL(fileURLWithPath: target.localPath), to: target.remotePath, resumeFrom: offset, cancel: token, progress: progress)
            }
            setStatus(id, .finished)
            release(s, siteID: site.id)
            refreshPanes(for: target)
        } catch {
            let message = error.localizedDescription
            // Cancelled, host key or certificate rejected, login refused, permission denied, file missing:
            // retrying would only ask again or fail the same way.
            if TransferRetry.isPermanent(error) {
                // The connection itself worked (a failed login never returns one), so it can be reused.
                if let session { release(session, siteID: site.id) }
                if case RemoteSSHError.cancelled = error {} else { model.error("\(item.fileName): \(message)") }
                setStatus(id, .failed, error: message)
                return
            }
            // Connection-level failures: drop the session and retry.
            if let session { AppModel.close(session) }
            // A pooled connection may have gone stale while it was idle: one free retry on a new connection.
            if reused, freshRetried.insert(id).inserted {
                model.status("Retrying \(item.fileName) on a new connection: \(message)")
                setStatus(id, .queued)
                return
            }
            let attempts = retries[id, default: 0]
            if attempts < model.settings.retryCount {
                retries[id] = attempts + 1
                let delay = TransferRetry.delay(forAttempt: attempts + 1)
                model.status("Retrying \(item.fileName) in \(delay.components.seconds) s (\(attempts + 1)/\(model.settings.retryCount)): \(message)")
                retryAt[id] = .now + delay
                setStatus(id, .queued)
                Task { [weak self] in
                    try? await Task.sleep(for: delay)
                    self?.resume()
                }
            } else {
                model.error("\(item.fileName): \(message)")
                setStatus(id, .failed, error: message)
            }
        }
    }

    private func update(_ id: UUID, progress p: TransferProgress, offset: Int64, started: Date) {
        guard let i = index(id) else { return }
        items[i].transferred = p.transferred
        if let t = p.total { items[i].size = t }
        let elapsed = Date().timeIntervalSince(started)
        if elapsed > 0.5 { speeds[id] = Double(p.transferred - offset) / elapsed }
    }

    /// Returns the resume offset (0 = from scratch) or nil to skip the file.
    private func resolveConflict(_ item: TransferItem, session: RemoteSession) async throws -> Int64? {
        if forceOverwrite.remove(item.id) != nil { return 0 }
        let source: PromptKind.FileInfo
        let target: PromptKind.FileInfo
        if item.direction == .download {
            guard let localSize = LocalFileSystem.size(item.localPath) else { return 0 }
            source = .init(path: item.remotePath, size: item.size, modified: nil)
            target = .init(path: item.localPath, size: localSize, modified: LocalFileSystem.modified(item.localPath))
        } else {
            guard let remoteSize = try await session.fileSize(item.remotePath) else { return 0 }
            source = .init(path: item.localPath, size: item.size, modified: LocalFileSystem.modified(item.localPath))
            target = .init(path: item.remotePath, size: remoteSize, modified: nil)
        }

        var action = item.direction == .download ? model.settings.defaultOverwriteDownload : model.settings.defaultOverwriteUpload
        if action == .ask, let remembered = overwriteForAll[item.direction] { action = remembered }
        if action == .ask {
            if case .overwrite(let chosen, let all) = await model.prompts.ask(.overwrite(file: item.fileName, source: source, target: target, direction: item.direction)) {
                action = chosen
                if all { overwriteForAll[item.direction] = chosen }
            } else {
                return nil
            }
        }

        switch action {
        case .ask, .overwrite:
            return 0
        case .skip:
            return nil
        case .overwriteIfDifferentSize:
            return source.size == target.size ? nil : 0
        case .overwriteIfNewer:
            if let s = source.modified, let t = target.modified { return s > t ? 0 : nil }
            return 0
        case .resume:
            // Resume only when the target is a shorter prefix; equal size = already complete.
            guard let t = target.size, let s = source.size else { return 0 }
            if t == s { return nil }
            return t < s ? t : 0
        case .rename:
            if item.direction == .download {
                let newPath = LocalFileSystem.uniqueName(for: item.localPath) { FileManager.default.fileExists(atPath: $0) }
                if let i = index(item.id) { items[i].localPath = newPath }
            } else {
                // Ask until the name is free: keeping the suggested name (or naming another existing file) would overwrite it.
                var message = "Enter a new name for the remote file:"
                while true {
                    guard let name = await model.prompts.requestText(title: "Rename file", message: message, initial: RemotePath.lastComponent(of: item.remotePath), icon: "pencil") else { return nil }
                    let newPath = RemotePath.join(RemotePath.parent(of: item.remotePath), name)
                    if !name.isEmpty, !name.contains("/"), try await session.fileSize(newPath) == nil {
                        if let i = index(item.id) { items[i].remotePath = newPath }
                        break
                    }
                    message = "“\(name)” already exists or is not a valid name. Enter another name:"
                }
            }
            return 0
        }
    }

    private func refreshPanes(for item: TransferItem) {
        let dir = item.direction == .download ? (item.localPath as NSString).deletingLastPathComponent : RemotePath.parent(of: item.remotePath)
        if item.direction == .download, dir == model.localPath { model.refreshLocal() }
        if item.direction == .upload, dir == model.remotePath, activeCount <= 1 { model.refreshRemote() }
    }

    /// Saves at most twice a second; the store writes only changed rows, on `saveQueue`.
    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            saveScheduled = false
            let snapshot = items
            let store = self.store
            saveQueue.async {
                let ok = store.save(snapshot)
                Task { @MainActor in self.noteSave(ok) }
            }
        }
    }

    private func noteSave(_ ok: Bool) {
        // Report a failure once, not on every later save.
        if !ok && !saveFailed { model.error("Could not save the transfer queue; pending transfers may be lost on quit.") }
        saveFailed = !ok
    }
}

/// Engines report progress per network chunk (thousands of times per second on fast links);
/// forward at most ~10 updates per second per transfer, plus the final one.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last: UInt64 = 0
    private static let interval: UInt64 = 100_000_000  // ns

    func shouldEmit(_ p: TransferProgress) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds  // read under the lock so `now - last` can't underflow
        if p.total == p.transferred || now - last >= Self.interval {
            last = now
            return true
        }
        return false
    }
}
