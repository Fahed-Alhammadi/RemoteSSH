import Foundation

public enum LogKind: String, Sendable {
    case status, command, response, error, trace
}

public struct LogLine: Identifiable, Sendable {
    public let id = UUID()
    public let date = Date()
    public let kind: LogKind
    public let text: String

    public init(_ kind: LogKind, _ text: String) {
        self.kind = kind
        self.text = text
    }
}

public typealias LogSink = @Sendable (LogLine) -> Void

/// Interactive questions the engine can ask the UI.
public protocol SessionPrompter: AnyObject, Sendable {
    /// Unknown or changed SSH host key. Return true to trust (and remember) it.
    func confirmHostKey(host: String, port: Int, keyType: String, fingerprint: String, changed: Bool) async -> Bool
    /// TLS certificate failed verification. Return true to connect anyway (remembered for the site).
    func confirmCertificate(host: String, port: Int, reason: String) async -> Bool
    /// Password for "Ask for password" sites or encrypted key files.
    func requestPassword(prompt: String) async -> String?
}

public struct TransferProgress: Sendable {
    public var transferred: Int64
    public var total: Int64?

    public init(transferred: Int64, total: Int64?) {
        self.transferred = transferred
        self.total = total
    }
}

public typealias ProgressHandler = @Sendable (TransferProgress) -> Void

/// Thread-safe cancellation flag shared between UI and a running transfer.
public final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _cancelled
    }

    public func cancel() {
        lock.lock(); _cancelled = true; lock.unlock()
    }
}

public protocol RemoteSession: AnyObject, Sendable {
    var site: Site { get }
    func connect() async throws
    func disconnect() async
    /// Absolute path of the login (home) directory.
    func homeDirectory() async throws -> String
    func list(_ path: String) async throws -> [FileEntry]
    func makeDirectory(_ path: String) async throws
    func deleteFile(_ path: String) async throws
    func removeDirectory(_ path: String) async throws
    func rename(_ from: String, to: String) async throws
    func chmod(_ path: String, mode: Int) async throws
    /// Size of a remote file, nil if it doesn't exist.
    func fileSize(_ path: String) async throws -> Int64?
    func download(_ remotePath: String, to localURL: URL, resumeFrom offset: Int64, cancel: CancelToken, progress: @escaping ProgressHandler) async throws
    func upload(_ localURL: URL, to remotePath: String, resumeFrom offset: Int64, cancel: CancelToken, progress: @escaping ProgressHandler) async throws
    /// FTP only: send a raw command (Server → Enter custom command).
    func rawCommand(_ command: String) async throws -> String
}

public struct SessionCredentials: Sendable {
    public var password: String
    public var keyPassphrase: String?

    public init(password: String, keyPassphrase: String? = nil) {
        self.password = password
        self.keyPassphrase = keyPassphrase
    }
}

public struct SessionOptions: Sendable {
    public var connectTimeout: Int = 20
    /// Bytes per second, 0 = unlimited.
    public var downloadLimit: Int = 0
    public var uploadLimit: Int = 0
    public var keepAlive: Bool = true

    public init() {}
}

public enum SessionFactory {
    public static func make(
        site: Site,
        credentials: SessionCredentials,
        options: SessionOptions,
        prompter: SessionPrompter?,
        hostKeys: KnownHostsStore,
        log: @escaping LogSink
    ) -> RemoteSession {
        switch site.serverProtocol {
        case .ftp:
            return FTPSession(site: site, credentials: credentials, options: options, prompter: prompter, log: log)
        case .sftp:
            return SFTPSession(site: site, credentials: credentials, options: options, prompter: prompter, hostKeys: hostKeys, log: log)
        }
    }
}
