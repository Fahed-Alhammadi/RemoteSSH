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

/// Persists the queue in SQLite so pending transfers survive a restart.
public final class QueueStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let lock = NSLock()

    public init(url: URL = AppPaths.file("queue.sqlite3")) {
        if sqlite3_open(url.path, &db) == SQLITE_OK {
            exec("""
            CREATE TABLE IF NOT EXISTS items (
                id TEXT PRIMARY KEY, site_id TEXT NOT NULL, direction INTEGER NOT NULL,
                local_path TEXT NOT NULL, remote_path TEXT NOT NULL, size INTEGER,
                status INTEGER NOT NULL, error TEXT, position INTEGER NOT NULL)
            """)
        }
    }

    deinit { sqlite3_close(db) }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Replaces the stored queue with the unfinished items.
    public func save(_ items: [TransferItem]) {
        lock.lock(); defer { lock.unlock() }
        exec("BEGIN")
        exec("DELETE FROM items")
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO items VALUES (?,?,?,?,?,?,?,?,?)", -1, &stmt, nil)
        for (pos, item) in items.enumerated() where item.status != .finished {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, item.id.uuidString, -1, Self.transient)
            sqlite3_bind_text(stmt, 2, item.siteID.uuidString, -1, Self.transient)
            sqlite3_bind_int(stmt, 3, Int32(item.direction.rawValue))
            sqlite3_bind_text(stmt, 4, item.localPath, -1, Self.transient)
            sqlite3_bind_text(stmt, 5, item.remotePath, -1, Self.transient)
            if let size = item.size { sqlite3_bind_int64(stmt, 6, size) } else { sqlite3_bind_null(stmt, 6) }
            // An interrupted transfer is re-queued on next launch.
            sqlite3_bind_int(stmt, 7, Int32(item.status == .transferring ? TransferStatus.queued.rawValue : item.status.rawValue))
            if let e = item.error { sqlite3_bind_text(stmt, 8, e, -1, Self.transient) } else { sqlite3_bind_null(stmt, 8) }
            sqlite3_bind_int(stmt, 9, Int32(pos))
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        exec("COMMIT")
    }

    public func load() -> [TransferItem] {
        lock.lock(); defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, site_id, direction, local_path, remote_path, size, status, error FROM items ORDER BY position", -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var items: [TransferItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            func str(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
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
        }
        return items
    }
}
