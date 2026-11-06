import Foundation
import SQLite3

public enum TransferDirection: Int, Codable, Sendable {
    case download = 0
    case upload = 1
}

public enum TransferStatus: Int, Codable, Sendable {
    case queued = 0
    case transferring = 1
    case finished = 2
    case failed = 3
}

/// What to do when the target file already exists.
public enum OverwriteAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case ask
    case overwrite
    case overwriteIfNewer
    case overwriteIfDifferentSize
    case resume
    case rename
    case skip

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .ask: return "Ask for action"
        case .overwrite: return "Overwrite file"
        case .overwriteIfNewer: return "Overwrite file if source newer"
        case .overwriteIfDifferentSize: return "Overwrite file if size differs"
        case .resume: return "Resume file transfer"
        case .rename: return "Rename file"
        case .skip: return "Skip file"
        }
    }
}

public struct TransferItem: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var siteID: UUID
    public var direction: TransferDirection
    public var localPath: String
    public var remotePath: String
    public var size: Int64?
    public var status: TransferStatus
    public var transferred: Int64
    public var error: String?
    public var finishedAt: Date?

    public init(siteID: UUID, direction: TransferDirection, localPath: String, remotePath: String, size: Int64?) {
        self.id = UUID()
        self.siteID = siteID
        self.direction = direction
        self.localPath = localPath
        self.remotePath = remotePath
        self.size = size
        self.status = .queued
        self.transferred = 0
    }

    public var fileName: String { (localPath as NSString).lastPathComponent }
}

/// When a failed transfer is tried again.
public enum TransferRetry {
    /// Failures a retry can't fix: cancelled by the user, host key or certificate rejected, login refused,
    /// permission denied, or a local or remote file that doesn't exist.
    public static func isPermanent(_ error: Error) -> Bool {
        switch error {
        case RemoteSSHError.cancelled, RemoteSSHError.hostKeyRejected, RemoteSSHError.certificateRejected,
             RemoteSSHError.authenticationFailed, RemoteSSHError.accessDenied, RemoteSSHError.fileNotFound,
             RemoteSSHError.invalidInput, RemoteSSHError.unsupported:
            return true
        default:
            break
        }
        if let cocoa = error as? CocoaError,
           [.fileNoSuchFile, .fileReadNoSuchFile, .fileReadNoPermission, .fileWriteNoPermission, .fileWriteVolumeReadOnly].contains(cocoa.code) {
            return true
        }
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain, [ENOENT, EACCES, EPERM, EROFS, EISDIR, ENOTDIR].contains(Int32(ns.code)) {
            return true
        }
        let text = "\(error)".lowercased()
        return ["permission denied", "access denied", "no such file"].contains { text.contains($0) }
    }

    /// The pause before counted retry `attempt` (1-based): 1, 2, 4, then at most 8 seconds.
    public static func delay(forAttempt attempt: Int) -> Duration {
        .seconds(1 << min(max(attempt - 1, 0), 3))
    }
}

/// Persists the queue in SQLite so pending transfers survive a restart. `save` writes only the rows that
/// changed since the last save, in one transaction (WAL journal), and is safe to call off the main thread.
public final class QueueStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()
    /// The table's contents as last written, by id.
    private var stored: [UUID: Row] = [:]
    private var nextPosition: Int64 = 0

    private struct Row: Equatable {
        var siteID: UUID
        var direction: TransferDirection
        var localPath: String
        var remotePath: String
        var size: Int64?
        var status: TransferStatus
        var error: String?

        init(_ item: TransferItem) {
            siteID = item.siteID
            direction = item.direction
            localPath = item.localPath
            remotePath = item.remotePath
            size = item.size
            // An interrupted transfer is re-queued on next launch.
            status = item.status == .transferring ? .queued : item.status
            error = item.error
        }
    }

    public init(url: URL = AppPaths.file("queue.sqlite3")) {
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            sqlite3_close(db)
            db = nil
            return
        }
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        exec("""
        CREATE TABLE IF NOT EXISTS items (
            id TEXT PRIMARY KEY, site_id TEXT NOT NULL, direction INTEGER NOT NULL,
            local_path TEXT NOT NULL, remote_path TEXT NOT NULL, size INTEGER,
            status INTEGER NOT NULL, error TEXT, position INTEGER NOT NULL)
        """)
    }

    deinit { sqlite3_close(db) }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ text: String?) {
        if let text { sqlite3_bind_text(stmt, index, text, -1, Self.transient) } else { sqlite3_bind_null(stmt, index) }
    }

    /// Binds site_id … error to parameters `first` … `first + 6`.
    private func bind(_ stmt: OpaquePointer?, _ row: Row, from first: Int32) {
        bind(stmt, first, row.siteID.uuidString)
        sqlite3_bind_int(stmt, first + 1, Int32(row.direction.rawValue))
        bind(stmt, first + 2, row.localPath)
        bind(stmt, first + 3, row.remotePath)
        if let size = row.size { sqlite3_bind_int64(stmt, first + 4, size) } else { sqlite3_bind_null(stmt, first + 4) }
        sqlite3_bind_int(stmt, first + 5, Int32(row.status.rawValue))
        bind(stmt, first + 6, row.error)
    }

    /// Runs `sql` once per id; false on the first SQLite error.
    private func each(_ sql: String, _ ids: [UUID], _ bindRow: (OpaquePointer?, UUID) -> Void) -> Bool {
        guard !ids.isEmpty else { return true }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        for id in ids {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bindRow(stmt, id)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        }
        return true
    }

    /// Stores the unfinished items (finished ones are dropped). Returns false when SQLite failed; nothing
    /// is changed then, and the next save tries again.
    @discardableResult
    public func save(_ items: [TransferItem]) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard db != nil else { return false }
        var wanted: [UUID: Row] = [:]
        var order: [UUID] = []
        for item in items where item.status != .finished && wanted[item.id] == nil {
            wanted[item.id] = Row(item)
            order.append(item.id)
        }
        let removed = stored.keys.filter { wanted[$0] == nil }
        let changed = order.filter { stored[$0] != nil && stored[$0] != wanted[$0] }
        let added = order.filter { stored[$0] == nil }
        if removed.isEmpty && changed.isEmpty && added.isEmpty { return true }

        guard exec("BEGIN IMMEDIATE") else { return false }
        var position = nextPosition
        let ok = each("DELETE FROM items WHERE id = ?", removed) { stmt, id in self.bind(stmt, 1, id.uuidString) }
            && each("UPDATE items SET site_id=?, direction=?, local_path=?, remote_path=?, size=?, status=?, error=? WHERE id=?", changed) { stmt, id in
                self.bind(stmt, wanted[id]!, from: 1)
                self.bind(stmt, 8, id.uuidString)
            }
            && each("INSERT OR REPLACE INTO items VALUES (?,?,?,?,?,?,?,?,?)", added) { stmt, id in
                self.bind(stmt, 1, id.uuidString)
                self.bind(stmt, wanted[id]!, from: 2)
                sqlite3_bind_int64(stmt, 9, position)
                position += 1
            }
        guard ok, exec("COMMIT") else {
            exec("ROLLBACK")
            return false
        }
        stored = wanted
        nextPosition = position
        return true
    }

    public func load() -> [TransferItem] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, site_id, direction, local_path, remote_path, size, status, error, position FROM items ORDER BY position", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var items: [TransferItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func str(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
            nextPosition = max(nextPosition, sqlite3_column_int64(stmt, 8) + 1)
            guard let id = str(0).flatMap(UUID.init), let site = str(1).flatMap(UUID.init) else { continue }
            var item = TransferItem(
                siteID: site,
                direction: TransferDirection(rawValue: Int(sqlite3_column_int(stmt, 2))) ?? .download,
                localPath: str(3) ?? "",
                remotePath: str(4) ?? "",
                size: sqlite3_column_type(stmt, 5) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 5)
            )
            item.id = id
            item.status = TransferStatus(rawValue: Int(sqlite3_column_int(stmt, 6))) ?? .queued
            item.error = str(7)
            items.append(item)
            stored[id] = Row(item)
        }
        return items
    }
}
