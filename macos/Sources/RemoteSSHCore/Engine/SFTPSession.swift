import Citadel
import CryptoKit
import Foundation
import NIOCore
import NIOSSH

/// SFTP session over SSH (Citadel / SwiftNIO-SSH).
public final class SFTPSession: RemoteSession, @unchecked Sendable {
    public let site: Site
    private let credentials: SessionCredentials
    private let options: SessionOptions
    private weak var prompter: SessionPrompter?
    private let hostKeys: KnownHostsStore
    private let log: LogSink
    private var client: SSHClient?
    private var sftp: SFTPClient?

    private static let chunkSize: UInt32 = 32 * 1024
    private static let pipelineDepth = 8

    init(site: Site, credentials: SessionCredentials, options: SessionOptions, prompter: SessionPrompter?, hostKeys: KnownHostsStore, log: @escaping LogSink) {
        self.site = site
        self.credentials = credentials
        self.options = options
        self.prompter = prompter
        self.hostKeys = hostKeys
        self.log = log
    }

    private func requireSFTP() throws -> SFTPClient {
        guard let sftp else { throw RemoteSSHError.notConnected }
        return sftp
    }

    // MARK: Authentication

    private func authenticationMethod() async throws -> SSHAuthenticationMethod {
        let user = site.effectiveUser
        guard site.logonType == .keyFile else {
            return .passwordBased(username: user, password: credentials.password)
        }
        let path = (site.keyFilePath as NSString).expandingTildeInPath
        guard let keyText = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw RemoteSSHError.invalidInput("Cannot read key file \(path)")
        }
        guard keyText.contains("BEGIN OPENSSH PRIVATE KEY") else {
            throw RemoteSSHError.unsupported("Only OpenSSH-format private keys are supported. Convert with: ssh-keygen -p -f \(path)")
        }
        guard let container = OpenSSHKeyFile(keyText) else {
            throw RemoteSSHError.invalidInput("Key file \(path) is not a valid OpenSSH private key")
        }
        // Citadel rejects valid keys whose unencrypted section is padded to 16 bytes.
        let parseText = container.canonicalPaddingText() ?? keyText
        let type = try SSHKeyDetection.detectPrivateKeyType(from: parseText)

        func load(_ passphrase: String?) throws -> SSHAuthenticationMethod {
            let pass = passphrase.map { Data($0.utf8) }
            if type == .ed25519 {
                return .ed25519(username: user, privateKey: try Curve25519.Signing.PrivateKey(sshEd25519: parseText, decryptionKey: pass))
            }
            if type == .rsa {
                let key = try Insecure.RSA.PrivateKey(sshRsa: parseText, decryptionKey: pass)
                return .custom(RSAAuthDelegate(username: user, key: key))
            }
            throw RemoteSSHError.unsupported("Key type \(type) is not supported; use an Ed25519 or RSA key.")
        }

        func parseError(_ error: Error) -> RemoteSSHError {
            if let e = error as? RemoteSSHError { return e }
            return .invalidInput("Could not load key file \(path): \(error)")
        }

        guard container.isEncrypted else {
            do { return try load(nil) } catch { throw parseError(error) }
        }
        if let pass = credentials.keyPassphrase, let method = try? load(pass) {
            return method
        }
        guard let pass = await prompter?.requestPassword(prompt: "Enter the passphrase for key file \(path)") else {
            throw RemoteSSHError.authenticationFailed("Key file is encrypted and no passphrase was given")
        }
        do { return try load(pass) } catch {
            throw RemoteSSHError.authenticationFailed("Wrong passphrase for key file \(path)")
        }
    }

    // MARK: RemoteSession

    public func connect() async throws {
        log(LogLine(.status, "Connecting to \(site.host):\(site.effectivePort)..."))
        let auth = try await authenticationMethod()
        let validator = HostKeyValidator(host: site.host, port: site.effectivePort, store: hostKeys, prompter: prompter, log: log)
        var settings = SSHClientSettings(
            host: site.host,
            port: site.effectivePort,
            authenticationMethod: { auth },
            hostKeyValidator: .custom(validator)
        )
        settings.connectTimeout = .seconds(Int64(options.connectTimeout))
        do {
            let client = try await SSHClient.connect(to: settings)
            self.client = client
            log(LogLine(.status, "Connected to \(site.host)"))
            sftp = try await client.openSFTP()
            log(LogLine(.response, "SFTP subsystem started"))
        } catch {
            if validator.rejected { throw RemoteSSHError.hostKeyRejected }
            if "\(error)".localizedCaseInsensitiveContains("auth") {
                throw RemoteSSHError.authenticationFailed(String(describing: error))
            }
            throw RemoteSSHError.connectionFailed(String(describing: error))
        }
    }

    public func disconnect() async {
        try? await sftp?.close()
        try? await client?.close()
        sftp = nil
        client = nil
        log(LogLine(.status, "Disconnected from server"))
    }

    public func homeDirectory() async throws -> String {
        try await requireSFTP().getRealPath(atPath: ".")
    }

    public func list(_ path: String) async throws -> [FileEntry] {
        let sftp = try requireSFTP()
        log(LogLine(.command, "ls \(path)"))
        let names = try await sftp.listDirectory(atPath: path)
        var entries: [FileEntry] = []
        for component in names.flatMap(\.components) where component.filename != "." && component.filename != ".." {
            var entry = Self.entry(from: component)
            if entry.isLink, let target = try? await sftp.getAttributes(at: RemotePath.join(path, component.filename)),
               let mode = target.permissions, mode & 0o170000 == 0o040000 {
                entry.isDirectory = true
            }
            entries.append(entry)
        }
        log(LogLine(.status, "Listing of \"\(path)\" successful (\(entries.count) entries)"))
        return entries
    }

    static func entry(from c: SFTPPathComponent) -> FileEntry {
        let mode = c.attributes.permissions ?? 0
        let longTokens = c.longname.split(separator: " ", omittingEmptySubsequences: true)
        return FileEntry(
            name: c.filename,
            isDirectory: mode & 0o170000 == 0o040000,
            isLink: mode & 0o170000 == 0o120000,
            size: c.attributes.size.map { Int64($0) },
            modified: c.attributes.accessModificationTime?.modificationTime,
            permissions: mode == 0 ? "" : Permissions.symbolic(mode: mode),
            owner: longTokens.count > 3 ? String(longTokens[2]) : (c.attributes.uidgid.map { String($0.userId) } ?? ""),
            group: longTokens.count > 3 ? String(longTokens[3]) : (c.attributes.uidgid.map { String($0.groupId) } ?? "")
        )
    }

    public func makeDirectory(_ path: String) async throws {
        log(LogLine(.command, "mkdir \(path)"))
        try await wrap { try await self.requireSFTP().createDirectory(atPath: path) }
    }

    public func deleteFile(_ path: String) async throws {
        log(LogLine(.command, "rm \(path)"))
        try await wrap { try await self.requireSFTP().remove(at: path) }
    }

    public func removeDirectory(_ path: String) async throws {
        log(LogLine(.command, "rmdir \(path)"))
        try await wrap { try await self.requireSFTP().rmdir(at: path) }
    }

    public func rename(_ from: String, to: String) async throws {
        log(LogLine(.command, "mv \(from) \(to)"))
        try await wrap { try await self.requireSFTP().rename(at: from, to: to) }
    }

    public func chmod(_ path: String, mode: Int) async throws {
        log(LogLine(.command, "chmod \(Permissions.octalString(mode)) \(path)"))
        var attrs = SFTPFileAttributes()
        attrs.permissions = UInt32(mode & 0o7777)
        try await wrap { try await self.requireSFTP().setAttributes(at: path, to: attrs) }
    }

    public func fileSize(_ path: String) async throws -> Int64? {
        guard let attrs = try? await requireSFTP().getAttributes(at: path) else { return nil }
        if let mode = attrs.permissions, mode & 0o170000 == 0o040000 { return nil }
        return attrs.size.map { Int64($0) }
    }

    public func rawCommand(_ command: String) async throws -> String {
        throw RemoteSSHError.unsupported("Custom commands are only supported with FTP.")
    }

    /// Runs an interactive login shell on a PTY (the terminal) until it exits or `shell.close()` is
    /// called; `output` receives everything it prints. When `dir` is not the login directory the
    /// shell changes to it first. Returns how the shell ended ("exit 1", "closed").
    public func runShell(_ shell: RemoteShell, cols: Int, rows: Int, startIn dir: String?,
                         output: @escaping @Sendable (Data) -> Void) async throws -> String {
        guard let client else { throw RemoteSSHError.notConnected }
        if let dir, dir != (try? await homeDirectory()) {
            // The leading space keeps the command out of shell history (HISTCONTROL=ignorespace).
            shell.write(" cd -- \(shellQuote(dir)) && clear\n")
        }
        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true, term: "xterm-256color",
            terminalCharacterWidth: cols, terminalRowHeight: rows,
            terminalPixelWidth: 0, terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )
        var ending = "closed"
        do {
            try await client.withPTY(request) { inbound, outbound in
                ending = try await withThrowingTaskGroup(of: String?.self) { group in
                    group.addTask {
                        for await operation in shell.operations { try await operation(outbound) }
                        return nil
                    }
                    group.addTask {
                        do {
                            for try await chunk in inbound {
                                switch chunk {
                                case .stdout(let bytes), .stderr(let bytes): output(Data(bytes.readableBytesView))
                                }
                            }
                        } catch let failed as SSHClient.CommandFailed {
                            return "exit \(failed.exitCode)"
                        }
                        return "closed"
                    }
                    // The shell exiting or close() (which ends the operations) ends the session.
                    let first = try await group.next() ?? nil
                    group.cancelAll()
                    return first ?? "closed"
                }
            }
        } catch let error as ChannelError where error == .alreadyClosed {
            // The server closed the channel when the shell exited; withPTY's own close() then fails.
        }
        return ending
    }

    private func wrap(_ body: @escaping () async throws -> Void) async throws {
        do { try await body() } catch let e as RemoteSSHError { throw e } catch {
            log(LogLine(.error, String(describing: error)))
            throw RemoteSSHError.commandFailed(String(describing: error))
        }
    }

    // MARK: Transfers (pipelined reads/writes)

    public func download(_ remotePath: String, to localURL: URL, resumeFrom offset: Int64, cancel: CancelToken, progress: @escaping ProgressHandler) async throws {
        let sftp = try requireSFTP()
        log(LogLine(.status, "Starting download of \(remotePath)"))
        let remote = try await sftp.openFile(filePath: remotePath, flags: .read)
        defer { Task { try? await remote.close() } }
        let total = try await remote.readAttributes().size.map { Int64($0) }

        let fm = FileManager.default
        if offset == 0 || !fm.fileExists(atPath: localURL.path) { fm.createFile(atPath: localURL.path, contents: nil) }
        let local = try FileHandle(forWritingTo: localURL)
        defer { try? local.close() }
        if offset > 0 { try local.seek(toOffset: UInt64(offset)) } else { try local.truncate(atOffset: 0) }

        var position = offset
        while true {
            if cancel.isCancelled { throw RemoteSSHError.cancelled }
            // Issue several reads concurrently, then write them in order.
            let start = position
            let chunks = try await withThrowingTaskGroup(of: (Int, ByteBuffer).self) { group in
                for i in 0..<Self.pipelineDepth {
                    let at = UInt64(start) + UInt64(i) * UInt64(Self.chunkSize)
                    if let total, Int64(at) >= total, i > 0 { break }
                    group.addTask { (i, try await remote.read(from: at, length: Self.chunkSize)) }
                }
                var result: [(Int, ByteBuffer)] = []
                for try await item in group { result.append(item) }
                return result.sorted { $0.0 < $1.0 }.map(\.1)
            }
            var reachedEnd = false
            for var buffer in chunks {
                let count = buffer.readableBytes
                if count == 0 { reachedEnd = true; break }
                if let bytes = buffer.readBytes(length: count) { try local.write(contentsOf: bytes) }
                position += Int64(count)
                if count < Int(Self.chunkSize) { reachedEnd = true; break }
            }
            progress(TransferProgress(transferred: position, total: total))
            if reachedEnd || (total != nil && position >= total!) { break }
        }
        log(LogLine(.status, "File transfer successful, transferred \(position - offset) bytes"))
    }

    public func upload(_ localURL: URL, to remotePath: String, resumeFrom offset: Int64, cancel: CancelToken, progress: @escaping ProgressHandler) async throws {
        let sftp = try requireSFTP()
        log(LogLine(.status, "Starting upload of \(localURL.path)"))
        let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int64) ?? 0
        let flags: SFTPOpenFileFlags = offset > 0 ? [.write, .create] : [.write, .create, .truncate]
        let remote = try await sftp.openFile(filePath: remotePath, flags: flags)
        let local = try FileHandle(forReadingFrom: localURL)
        defer { try? local.close() }
        if offset > 0 { try local.seek(toOffset: UInt64(offset)) }

        var position = offset
        do {
            while position < size {
                if cancel.isCancelled { throw RemoteSSHError.cancelled }
                var batch: [(UInt64, Data)] = []
                for _ in 0..<Self.pipelineDepth {
                    guard let data = try local.read(upToCount: Int(Self.chunkSize)), !data.isEmpty else { break }
                    batch.append((UInt64(position), data))
                    position += Int64(data.count)
                }
                if batch.isEmpty { break }
                try await withThrowingTaskGroup(of: Void.self) { group in
                    for (at, data) in batch {
                        group.addTask { try await remote.write(ByteBuffer(bytes: data), at: at) }
                    }
                    try await group.waitForAll()
                }
                progress(TransferProgress(transferred: position, total: size))
            }
            try await remote.close()
        } catch {
            try? await remote.close()
            throw error
        }
        log(LogLine(.status, "File transfer successful, transferred \(position - offset) bytes"))
    }
}

/// Bridges NIOSSH host key validation to the known-hosts store and the UI prompt.
final class HostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let host: String
    let port: Int
    let store: KnownHostsStore
    weak var prompter: SessionPrompter?
    let log: LogSink
    private(set) var rejected = false

    init(host: String, port: Int, store: KnownHostsStore, prompter: SessionPrompter?, log: @escaping LogSink) {
        self.host = host
        self.port = port
        self.store = store
        self.prompter = prompter
        self.log = log
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let openSSH = String(openSSHPublicKey: hostKey)
        let parts = openSSH.split(separator: " ")
        let keyType = parts.first.map(String.init) ?? "unknown"
        let fingerprint = KnownHostsStore.fingerprint(ofOpenSSHKey: openSSH)

        switch store.check(host: host, port: port, key: openSSH) {
        case .trusted:
            log(LogLine(.status, "Host key verified: \(keyType) \(fingerprint)"))
            validationCompletePromise.succeed(())
        case .unknown, .changed:
            let changed = store.check(host: host, port: port, key: openSSH) == .changed
            let prompter = self.prompter
            Task {
                let ok = await prompter?.confirmHostKey(host: host, port: port, keyType: keyType, fingerprint: fingerprint, changed: changed) ?? false
                if ok {
                    self.store.trust(host: self.host, port: self.port, key: openSSH)
                    validationCompletePromise.succeed(())
                } else {
                    self.rejected = true
                    validationCompletePromise.fail(RemoteSSHError.hostKeyRejected)
                }
            }
        }
    }
}
