import Foundation

public enum ServerProtocol: String, Codable, CaseIterable, Identifiable, Sendable {
    case ftp
    case sftp

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .ftp: return "FTP - File Transfer Protocol"
        case .sftp: return "SFTP - SSH File Transfer Protocol"
        }
    }
    public var defaultPort: Int { self == .sftp ? 22 : 21 }
}

/// TLS options for FTP connections.
public enum FTPEncryption: String, Codable, CaseIterable, Identifiable, Sendable {
    case explicitIfAvailable
    case requireExplicit
    case requireImplicit
    case plain

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .explicitIfAvailable: return "Use explicit FTP over TLS if available"
        case .requireExplicit: return "Require explicit FTP over TLS"
        case .requireImplicit: return "Require implicit FTP over TLS"
        case .plain: return "Only use plain FTP (insecure)"
        }
    }
}

public enum LogonType: String, Codable, CaseIterable, Identifiable, Sendable {
    case anonymous
    case normal
    case askForPassword
    case keyFile

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .anonymous: return "Anonymous"
        case .normal: return "Normal"
        case .askForPassword: return "Ask for password"
        case .keyFile: return "Key file"
        }
    }
}

public enum TransferMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case passive
    case active

    public var id: String { rawValue }
}

public struct Site: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// Slash separated folder in the site manager tree ("" = top level).
    public var folder: String
    public var host: String
    public var port: Int
    public var serverProtocol: ServerProtocol
    public var encryption: FTPEncryption
    public var logonType: LogonType
    public var user: String
    public var keyFilePath: String
    public var transferMode: TransferMode
    public var defaultLocalDirectory: String
    public var defaultRemoteDirectory: String
    public var comments: String
    /// Set after the user accepted an untrusted TLS certificate for this site.
    public var trustInvalidCertificate: Bool

    public init(
        id: UUID = UUID(),
        name: String = "New site",
        folder: String = "",
        host: String = "",
        port: Int = 0,
        serverProtocol: ServerProtocol = .sftp,
        encryption: FTPEncryption = .explicitIfAvailable,
        logonType: LogonType = .normal,
        user: String = "",
        keyFilePath: String = "",
        transferMode: TransferMode = .passive,
        defaultLocalDirectory: String = "",
        defaultRemoteDirectory: String = "",
        comments: String = "",
        trustInvalidCertificate: Bool = false
    ) {
        self.id = id
        self.name = name
        self.folder = folder
        self.host = host
        self.port = port
        self.serverProtocol = serverProtocol
        self.encryption = encryption
        self.logonType = logonType
        self.user = user
        self.keyFilePath = keyFilePath
        self.transferMode = transferMode
        self.defaultLocalDirectory = defaultLocalDirectory
        self.defaultRemoteDirectory = defaultRemoteDirectory
        self.comments = comments
        self.trustInvalidCertificate = trustInvalidCertificate
    }

    public var effectivePort: Int {
        if port > 0 { return port }
        if serverProtocol == .ftp && encryption == .requireImplicit { return 990 }
        return serverProtocol.defaultPort
    }

    public var effectiveUser: String {
        logonType == .anonymous ? "anonymous" : user
    }

    public var displayAddress: String {
        let scheme = serverProtocol == .sftp ? "sftp" : (encryption == .requireImplicit ? "ftps" : "ftp")
        let userPart = effectiveUser.isEmpty ? "" : "\(effectiveUser)@"
        return "\(scheme)://\(userPart)\(host):\(effectivePort)"
    }
}

/// Parses quickconnect input: the host field may carry a scheme and credentials,
/// e.g. `sftp://user:pass@example.com:2222/var/www`.
public struct QuickConnectInput: Sendable {
    public var site: Site
    public var password: String
    public var initialPath: String?

    public static func parse(host rawHost: String, user: String, password: String, port: String) throws -> QuickConnectInput {
        var hostString = rawHost.trimmingCharacters(in: .whitespaces)
        guard !hostString.isEmpty else { throw RemoteSSHError.invalidInput("You have to enter a hostname.") }

        var site = Site(name: hostString, serverProtocol: .ftp, logonType: .normal, user: user)
        var pass = password
        var initialPath: String?

        if let range = hostString.range(of: "://") {
            let scheme = hostString[..<range.lowerBound].lowercased()
            hostString = String(hostString[range.upperBound...])
            switch scheme {
            case "ftp": site.serverProtocol = .ftp; site.encryption = .explicitIfAvailable
            case "ftpes": site.serverProtocol = .ftp; site.encryption = .requireExplicit
            case "ftps": site.serverProtocol = .ftp; site.encryption = .requireImplicit
            case "sftp", "ssh": site.serverProtocol = .sftp
            default:
                throw RemoteSSHError.invalidInput("Invalid protocol specified. Valid protocols are: ftp://, ftps://, ftpes://, sftp://")
            }
        }

        if let slash = hostString.firstIndex(of: "/") {
            initialPath = String(hostString[slash...]).removingPercentEncoding
            hostString = String(hostString[..<slash])
        }
        if let at = hostString.lastIndex(of: "@") {
            let credentials = String(hostString[..<at])
            hostString = String(hostString[hostString.index(after: at)...])
            if let colon = credentials.firstIndex(of: ":") {
                site.user = String(credentials[..<colon]).removingPercentEncoding ?? ""
                pass = String(credentials[credentials.index(after: colon)...]).removingPercentEncoding ?? ""
            } else {
                site.user = credentials.removingPercentEncoding ?? credentials
            }
        }
        // host:port (IPv6 literals in brackets)
        if hostString.hasPrefix("["), let close = hostString.firstIndex(of: "]") {
            let after = hostString[hostString.index(after: close)...]
            if after.hasPrefix(":"), let p = Int(after.dropFirst()) { site.port = p }
            hostString = String(hostString[hostString.index(after: hostString.startIndex)..<close])
        } else if let colon = hostString.lastIndex(of: ":"), let p = Int(hostString[hostString.index(after: colon)...]) {
            site.port = p
            hostString = String(hostString[..<colon])
        }

        if let p = Int(port.trimmingCharacters(in: .whitespaces)), p > 0 {
            site.port = p
        }
        guard (0...65535).contains(site.port) else { throw RemoteSSHError.invalidInput("Invalid port given.") }
        if site.port == 22 && rawHost.range(of: "://") == nil { site.serverProtocol = .sftp }

        site.host = hostString
        site.name = hostString
        if site.user.isEmpty || site.user == "anonymous" {
            site.logonType = site.user.isEmpty && pass.isEmpty && site.serverProtocol == .ftp ? .anonymous : .normal
        }
        return QuickConnectInput(site: site, password: pass, initialPath: initialPath)
    }
}
