import Foundation

public struct FileEntry: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public var name: String
    public var isDirectory: Bool
    public var isLink: Bool
    public var size: Int64?
    public var modified: Date?
    /// Symbolic form, e.g. "drwxr-xr-x" or "0755" when only octal is known.
    public var permissions: String
    public var owner: String
    public var group: String
    public var linkTarget: String?

    public init(
        name: String,
        isDirectory: Bool,
        isLink: Bool = false,
        size: Int64? = nil,
        modified: Date? = nil,
        permissions: String = "",
        owner: String = "",
        group: String = "",
        linkTarget: String? = nil
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.isLink = isLink
        self.size = size
        self.modified = modified
        self.permissions = permissions
        self.owner = owner
        self.group = group
        self.linkTarget = linkTarget
    }

    public var isHidden: Bool { name.hasPrefix(".") }

    public var fileType: String {
        if isDirectory { return "Directory" }
        let ext = (name as NSString).pathExtension
        return ext.isEmpty ? "File" : "\(ext.uppercased())-file"
    }

    /// Octal permission bits parsed from `permissions`, if possible.
    public var permissionBits: Int? {
        Permissions.bits(from: permissions)
    }
}

public enum Permissions {
    public static func symbolic(mode: UInt32) -> String {
        let type: Character
        switch mode & 0o170000 {
        case 0o040000: type = "d"
        case 0o120000: type = "l"
        default: type = "-"
        }
        let chars: [Character] = ["r", "w", "x"]
        var out = String(type)
        for shift in stride(from: 6, through: 0, by: -3) {
            let bits = (mode >> UInt32(shift)) & 0o7
            for i in 0..<3 {
                out.append(bits & (0o4 >> UInt32(i)) != 0 ? chars[i] : "-")
            }
        }
        return out
    }

    public static func bits(from text: String) -> Int? {
        if text.count == 3 || text.count == 4, let v = Int(text, radix: 8) { return v & 0o777 }
        let s = Array(text)
        guard s.count >= 10 else { return nil }
        var mode = 0
        for (i, c) in s[1...9].enumerated() where c != "-" {
            if c == "S" || c == "T" { continue }
            mode |= 1 << (8 - i)
        }
        return mode
    }

    public static func octalString(_ bits: Int) -> String {
        String(format: "%03o", bits & 0o777)
    }
}

public enum RemotePath {
    public static func join(_ base: String, _ name: String) -> String {
        if name.hasPrefix("/") { return name }
        if base.hasSuffix("/") { return base + name }
        return base + "/" + name
    }

    public static func parent(of path: String) -> String {
        guard path != "/" else { return "/" }
        var trimmed = path
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let idx = trimmed.lastIndex(of: "/") else { return "/" }
        let parent = String(trimmed[..<idx])
        return parent.isEmpty ? "/" : parent
    }

    public static func lastComponent(of path: String) -> String {
        var trimmed = path
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed.split(separator: "/").last.map(String.init) ?? "/"
    }

    public static func normalize(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." || part.isEmpty { continue }
            if part == ".." { _ = parts.popLast(); continue }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }
}

public enum RemoteSSHError: LocalizedError, Sendable {
    case invalidInput(String)
    case connectionFailed(String)
    case notConnected
    case commandFailed(String)
    case cancelled
    case certificateRejected
    case hostKeyRejected
    case authenticationFailed(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .invalidInput(let m): return m
        case .connectionFailed(let m): return "Connection failed: \(m)"
        case .notConnected: return "Not connected."
        case .commandFailed(let m): return m
        case .cancelled: return "Interrupted by user"
        case .certificateRejected: return "The server certificate was not trusted."
        case .hostKeyRejected: return "The server's host key was rejected."
        case .authenticationFailed(let m): return "Authentication failed: \(m)"
        case .unsupported(let m): return m
        }
    }
}
