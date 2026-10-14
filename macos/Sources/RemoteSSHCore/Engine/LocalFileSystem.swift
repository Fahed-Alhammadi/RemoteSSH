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
