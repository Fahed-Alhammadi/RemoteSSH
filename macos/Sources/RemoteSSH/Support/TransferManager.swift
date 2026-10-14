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
    @ObservationIgnored private var retries: [UUID: Int] = [:]
    @ObservationIgnored private var overwriteForAll: [TransferDirection: OverwriteAction] = [:]
    @ObservationIgnored private var saveScheduled = false
    /// Items that skip the "file exists" check (View/Edit re-uploads).
    @ObservationIgnored private var forceOverwrite: Set<UUID> = []

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

    func enqueueDownload(entries: [FileEntry], remoteDir: String, localDir: String, site: Site) {
        Task {
            for entry in entries {
                let remote = RemotePath.join(remoteDir, entry.name)
                let local = (localDir as NSString).appendingPathComponent(entry.name)
                if entry.isDirectory {
                    await expandRemoteDirectory(remote: remote, local: local, site: site)
                } else {
                    add(TransferItem(siteID: site.id, direction: .download, localPath: local, remotePath: remote, size: entry.size))
                }
            }
            resume()
        }
    }

    private func expandRemoteDirectory(remote: String, local: String, site: Site) async {
        guard let session = model.session else { return }
        do {
            try FileManager.default.createDirectory(atPath: local, withIntermediateDirectories: true)
            for child in try await session.list(remote) {
                let r = RemotePath.join(remote, child.name)
                let l = (local as NSString).appendingPathComponent(child.name)
                if child.isDirectory {
                    await expandRemoteDirectory(remote: r, local: l, site: site)
                } else {
                    add(TransferItem(siteID: site.id, direction: .download, localPath: l, remotePath: r, size: child.size))
                }
            }
        } catch {
            model.error("Could not list \(remote): \(error.localizedDescription)")
        }
    }

    func enqueueUpload(localPaths: [String], remoteDir: String, site: Site) {
        Task {
            for path in localPaths {
                let remote = RemotePath.join(remoteDir, (path as NSString).lastPathComponent)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { continue }
                if isDir.boolValue {
                    await expandLocalDirectory(local: path, remote: remote, site: site)
                } else {
                    add(TransferItem(siteID: site.id, direction: .upload, localPath: path, remotePath: remote, size: LocalFileSystem.size(path)))
                }
            }
            resume()
        }
    }

    private func expandLocalDirectory(local: String, remote: String, site: Site) async {
        if let session = model.session { try? await session.makeDirectory(remote) }  // may already exist
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: local) else { return }
        for name in children.sorted() {
            let l = (local as NSString).appendingPathComponent(name)
            let r = RemotePath.join(remote, name)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: l, isDirectory: &isDir)
            if isDir.boolValue {
                await expandLocalDirectory(local: l, remote: r, site: site)
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
        let next = items.filter { $0.status == .queued }.prefix(free)
        for item in next {
            setStatus(item.id, .transferring)
            Task { await run(item.id) }
        }
    }

    func toggleProcessing() {
        processing.toggle()
        if processing { resume() }
    }

    func cancel(_ ids: Set<UUID>) {
        for id in ids { cancelTokens[id]?.cancel() }
    }

    func remove(_ ids: Set<UUID>) {
        cancel(ids)
        items.removeAll { ids.contains($0.id) && $0.status != .transferring }
        scheduleSave()
    }

    func retry(_ ids: Set<UUID>) {
        for i in items.indices where ids.contains(items[i].id) && items[i].status == .failed {
            items[i].status = .queued
            items[i].error = nil
            items[i].transferred = 0
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

    private func acquireSession(for site: Site) async throws -> RemoteSession {
        if var pool = idleSessions[site.id], !pool.isEmpty {
            let s = pool.removeLast()
            idleSessions[site.id] = pool
            return s
        }
        let session = model.makeSession(for: site, password: model.password(for: site) ?? "")
        try await session.connect()
        return session
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
            resume()
        }

        var session: RemoteSession?
        do {
            let s = try await acquireSession(for: site)
            session = s
            guard let offset = try await resolveConflict(item, session: s) else {
                setStatus(id, .finished, error: "Skipped")
                release(s, siteID: site.id)
                return
            }
            let started = Date()
            let throttle = ProgressThrottle()
            let progress: ProgressHandler = { [weak self] p in
                guard throttle.shouldEmit(p) else { return }
                Task { @MainActor in self?.update(id, progress: p, offset: offset, started: started) }
            }
            if item.direction == .download {
                try FileManager.default.createDirectory(atPath: (item.localPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                try await s.download(item.remotePath, to: URL(fileURLWithPath: item.localPath), resumeFrom: offset, cancel: token, progress: progress)
            } else {
                try await s.upload(URL(fileURLWithPath: item.localPath), to: item.remotePath, resumeFrom: offset, cancel: token, progress: progress)
            }
            setStatus(id, .finished)
            release(s, siteID: site.id)
            refreshPanes(for: item)
        } catch {
            let message = error.localizedDescription
            if case RemoteSSHError.cancelled = error {
                setStatus(id, .failed, error: message)
                if let session { release(session, siteID: site.id) }
                return
            }
            // Connection-level failures: drop the session and retry a few times.
            if let session { await session.disconnect() }
            let attempts = retries[id, default: 0]
            if attempts < model.settings.retryCount {
                retries[id] = attempts + 1
                model.status("Retrying \(item.fileName) (\(attempts + 1)/\(model.settings.retryCount)): \(message)")
                setStatus(id, .queued)
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
            } else if let name = await model.prompts.requestText(title: "Rename file", message: "Enter a new name for the remote file:", initial: RemotePath.lastComponent(of: item.remotePath)) {
                if let i = index(item.id) { items[i].remotePath = RemotePath.join(RemotePath.parent(of: item.remotePath), name) }
            } else {
                return nil
            }
            return 0
        }
    }

    private func refreshPanes(for item: TransferItem) {
        let dir = item.direction == .download ? (item.localPath as NSString).deletingLastPathComponent : RemotePath.parent(of: item.remotePath)
        if item.direction == .download, dir == model.localPath { model.refreshLocal() }
        if item.direction == .upload, dir == model.remotePath, activeCount <= 1 { model.refreshRemote() }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            saveScheduled = false
            store.save(items)
        }
    }
}

/// Engines report progress per network chunk (thousands of times per second on fast links);
/// forward at most ~10 updates per second per transfer, plus the final one.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last: UInt64 = 0
    private static let interval: UInt64 = 100_000_000  // ns

    func shouldEmit(_ p: TransferProgress) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock(); defer { lock.unlock() }
        if p.total == p.transferred || now - last >= Self.interval {
            last = now
            return true
        }
        return false
    }
}
