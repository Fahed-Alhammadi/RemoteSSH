import Foundation

/// Local side of the dual-pane browser.
public enum LocalFileSystem {
    public static func list(_ path: String) throws -> [FileEntry] {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let contents = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])
        return contents.map { item in
            let values = try? item.resourceValues(forKeys: Set(keys))
            let attrs = try? FileManager.default.attributesOfItem(atPath: item.path)
            let posix = (attrs?[.posixPermissions] as? NSNumber)?.uint32Value ?? 0
            let isDir = values?.isDirectory ?? false
            return FileEntry(
                name: item.lastPathComponent,
                isDirectory: isDir,
                isLink: values?.isSymbolicLink ?? false,
                size: isDir ? nil : (values?.fileSize).map { Int64($0) },
                modified: values?.contentModificationDate,
                permissions: Permissions.symbolic(mode: posix | (isDir ? 0o040000 : 0)),
                owner: attrs?[.ownerAccountName] as? String ?? "",
                group: attrs?[.groupOwnerAccountName] as? String ?? ""
            )
        }
    }

    public static func size(_ path: String) -> Int64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              (attrs[.type] as? FileAttributeType) != .typeDirectory else { return nil }
        return (attrs[.size] as? NSNumber)?.int64Value
    }

    public static func modified(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    /// Unique name for the "Rename file" action: "file (1).txt".
    public static func uniqueName(for path: String, exists: (String) -> Bool) -> String {
        let ns = path as NSString
        let dir = ns.deletingLastPathComponent
        let ext = ns.pathExtension
        let base = (ns.lastPathComponent as NSString).deletingPathExtension
        var i = 1
        while true {
            let name = ext.isEmpty ? "\(base) (\(i))" : "\(base) (\(i)).\(ext)"
            let candidate = (dir as NSString).appendingPathComponent(name)
            if !exists(candidate) { return candidate }
            i += 1
        }
    }
}

/// The local file a download writes to. A fresh download goes to a temporary sibling
/// (`<name>.remotessh-part`) that replaces the target only once the transfer succeeded, so a failed or
/// cancelled overwrite leaves the old file intact. A resumed download (offset > 0) appends to the target.
final class DownloadTarget {
    let handle: FileHandle
    private let target: URL
    private let temporary: URL?

    static func partURL(for target: URL) -> URL {
        target.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + ".remotessh-part")
    }

    init(_ target: URL, resumeFrom offset: Int64) throws {
        let fm = FileManager.default
        self.target = target
        if offset > 0 {
            temporary = nil
            if !fm.fileExists(atPath: target.path) { fm.createFile(atPath: target.path, contents: nil) }
            handle = try FileHandle(forWritingTo: target)
            try handle.seek(toOffset: UInt64(offset))
        } else {
            let part = Self.partURL(for: target)
            guard fm.createFile(atPath: part.path, contents: nil) else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: part.path])
            }
            temporary = part
            handle = try FileHandle(forWritingTo: part)
        }
    }

    /// Closes the file and, for a fresh download, moves it over the target (atomic rename).
    func commit() throws {
        try handle.close()
        guard let temporary else { return }
        if rename(temporary.path, target.path) != 0 {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            try? FileManager.default.removeItem(at: temporary)
            throw POSIXError(code)
        }
    }

    /// Closes the file and deletes the temporary copy (the target is untouched).
    func discard() {
        try? handle.close()
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
    }

    /// Runs `body` with the open file, then commits on success or discards on any error.
    static func write(to target: URL, resumeFrom offset: Int64, _ body: (DownloadTarget) async throws -> Void) async throws {
        let file = try DownloadTarget(target, resumeFrom: offset)
        do {
            try await body(file)
        } catch {
            file.discard()
            throw error
        }
        try file.commit()
    }
}

/// Directory comparison (View → Directory comparison) by name, size and date.
public enum DirectoryComparison {
    public enum State: Sendable { case same, onlyHere, newer, different }

    public static func compare(_ mine: [FileEntry], with other: [FileEntry]) -> [String: State] {
        let others = Dictionary(other.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var result: [String: State] = [:]
        for entry in mine {
            guard let o = others[entry.name] else { result[entry.name] = .onlyHere; continue }
            if entry.isDirectory || o.isDirectory { result[entry.name] = entry.isDirectory == o.isDirectory ? .same : .different; continue }
            if entry.size != o.size { result[entry.name] = .different }
            else if let a = entry.modified, let b = o.modified, a.timeIntervalSince(b) > 60 { result[entry.name] = .newer }
            else { result[entry.name] = .same }
        }
        return result
    }
}
