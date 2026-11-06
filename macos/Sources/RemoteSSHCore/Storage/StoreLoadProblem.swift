import Foundation

/// A data file (sites, known hosts) that exists but could not be read in full. The store keeps a copy of
/// the file and refuses to write over it until the app has told the user (`allowSaving()`).
public struct StoreLoadProblem: LocalizedError, Sendable {
    public let file: URL
    /// Where the unreadable file was copied, nil if the copy failed.
    public let backup: URL?
    public let detail: String

    public var errorDescription: String? {
        let copy = backup.map { " A copy of the file was saved as \($0.lastPathComponent)." } ?? ""
        return "\(file.lastPathComponent) could not be read: \(detail).\(copy)"
    }

    /// Copies `url` to `<name>.bak`. An existing backup with other contents is kept and the copy goes to
    /// `<name>.<date>.bak` instead, so an older, possibly good backup is never replaced.
    static func backUp(_ url: URL) -> URL? {
        let fm = FileManager.default
        guard let data = try? Data(contentsOf: url) else { return nil }
        var target = url.appendingPathExtension("bak")
        if let existing = try? Data(contentsOf: target) {
            if existing == data { return target }
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            target = url.appendingPathExtension(stamp).appendingPathExtension("bak")
        }
        guard !fm.fileExists(atPath: target.path), fm.createFile(atPath: target.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            return nil
        }
        return target
    }

    static func make(_ url: URL, _ error: Error?, detail: String? = nil) -> StoreLoadProblem {
        let text = detail ?? error.map { ($0 as? DecodingError).map(Self.describe) ?? $0.localizedDescription } ?? "unknown error"
        return StoreLoadProblem(file: url, backup: backUp(url), detail: text)
    }

    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .dataCorrupted(let c), .keyNotFound(_, let c), .typeMismatch(_, let c), .valueNotFound(_, let c):
            let path = c.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
            return path.isEmpty ? c.debugDescription : "\(c.debugDescription) (at \(path))"
        @unknown default:
            return "\(error)"
        }
    }
}
