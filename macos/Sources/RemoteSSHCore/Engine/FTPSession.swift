import CCurl
import Foundation

/// FTP / FTPS (explicit + implicit) session backed by the system libcurl.
/// One instance = one control connection; the transfer queue creates a separate session per
/// concurrent transfer.
public final class FTPSession: RemoteSession, @unchecked Sendable {
    private let credentials: SessionCredentials
    private let options: SessionOptions
    private weak var prompter: SessionPrompter?
    private let log: LogSink
    private let pins: CertificatePinStore
    private let queue: DispatchQueue
    /// Only touched on `queue`: created by the first request, freed there by `disconnect()`.
    private var handle: CurlHandle?
    /// Guards the mutable state below: operations on one session can run concurrently (browsing
    /// while a folder is being queued), and the curl queue reads `site` while callers update it.
    private let lock = NSLock()
    private var _site: Site
    private var listCommand: String?
    private var cachedHome: String?
    private var tlsActive = false
    /// Set by `disconnect()` without going through the queue: the running request stops at its next
    /// progress callback (curl calls it at least about once a second, also while connecting).
    private var aborted = false
    /// Base64 SHA-256 of the public key the user trusted; once set, it replaces CA verification.
    private var pinnedKey: String?

    public var site: Site { lock.withLock { _site } }

    /// Whether the control connection is encrypted. With "explicit TLS if available" this is only
    /// known after `connect()`: a server without AUTH TLS falls back to plain FTP.
    public var isEncrypted: Bool { lock.withLock { tlsActive } }

    init(site: Site, credentials: SessionCredentials, options: SessionOptions, prompter: SessionPrompter?,
         certificatePins: CertificatePinStore, log: @escaping LogSink) {
        self._site = site
        self.credentials = credentials
        self.options = options
        self.prompter = prompter
        self.pins = certificatePins
        self.log = log
        self.queue = DispatchQueue(label: "remotessh.ftp.\(site.host)")
    }

    deinit {
        // curl_easy_cleanup sends QUIT and can block: free the handle on the session queue, not on
        // whichever thread (often the main one) dropped the last reference to the session.
        if let handle { queue.async { withExtendedLifetime(handle) {} } }
    }

    private var isAborted: Bool { lock.withLock { aborted } }

    // MARK: URL building

    private var baseURL: String {
        let site = self.site
        let scheme = site.encryption == .requireImplicit ? "ftps" : "ftp"
        let host = site.host.contains(":") ? "[\(site.host)]" : site.host
        return "\(scheme)://\(host):\(site.effectivePort)"
    }

    private static let segmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/;?#%")
        return set
    }()

    /// Absolute path → URL. `%2F` after the host makes curl treat the path as absolute.
    private func url(for path: String, directory: Bool) -> String {
        let segments = path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: Self.segmentAllowed) ?? String($0)
        }
        var u = baseURL + "/%2F" + segments.joined(separator: "/")
        if directory && !u.hasSuffix("/") { u += "/" }
        return u
    }

    // MARK: Option setup

    private func applyBaseOptions(_ h: CurlHandle, pinning: Bool = true) {
        let site = self.site
        h.set(CURLOPT_USERNAME, site.effectiveUser.isEmpty ? "anonymous" : site.effectiveUser)
        h.set(CURLOPT_PASSWORD, site.logonType == .anonymous ? "anonymous@example.com" : credentials.password)
        h.set(CURLOPT_CONNECTTIMEOUT, options.connectTimeout)
        h.set(CURLOPT_SERVER_RESPONSE_TIMEOUT, 60)
        h.set(CURLOPT_LOW_SPEED_LIMIT, 1)
        h.set(CURLOPT_LOW_SPEED_TIME, 120)
        h.set(CURLOPT_TCP_KEEPALIVE, options.keepAlive ? 1 : 0)
        h.set(CURLOPT_FTP_FILEMETHOD, Int(CURLFTPMETHOD_SINGLECWD.rawValue))
        h.set(CURLOPT_FTP_USE_EPSV, 1)
        // Sessions run on several queues at once; signals aren't thread-safe (libcurl-thread).
        h.set(CURLOPT_NOSIGNAL, 1)
        // The system libcurl predates 8.16, whose default minimum is TLS 1.2.
        h.set(CURLOPT_SSLVERSION, Int(CURL_SSLVERSION_TLSv1_2))
        if site.transferMode == .active { h.set(CURLOPT_FTPPORT, "-") }
        switch site.encryption {
        case .explicitIfAvailable: h.set(CURLOPT_USE_SSL, Int(CURLUSESSL_TRY.rawValue))
        case .requireExplicit, .requireImplicit: h.set(CURLOPT_USE_SSL, Int(CURLUSESSL_ALL.rawValue))
        case .plain: h.set(CURLOPT_USE_SSL, Int(CURLUSESSL_NONE.rawValue))
        }
        if pinning, let pin = lock.withLock({ pinnedKey }) {
            // The user trusted this certificate's key: accept that key, and only it, without CA verification.
            // curl checks the pin on the control connection and on every TLS data connection.
            h.set(CURLOPT_SSL_VERIFYPEER, 0)
            h.set(CURLOPT_SSL_VERIFYHOST, 0)
            h.set(CURLOPT_PINNEDPUBLICKEY, "sha256//\(pin)")
        }
        if options.downloadLimit > 0 { h.set(CURLOPT_MAX_RECV_SPEED_LARGE, offset: Int64(options.downloadLimit)) }
        if options.uploadLimit > 0 { h.set(CURLOPT_MAX_SEND_SPEED_LARGE, offset: Int64(options.uploadLimit)) }
    }

    private struct CertificateFailure: Error {
        let message: String
        /// The certificate's key differs from the pinned one.
        var pinMismatch = false
    }

    /// Runs a curl operation on the session queue. When the certificate can't be verified, it switches to
    /// the key the user trusted (asking when there is none, or when it changed) and tries again.
    private func run<T>(_ body: @escaping (CurlHandle, CurlContext) throws -> T) async throws -> T {
        var failures = 0
        while true {
            do {
                return try await perform(body)
            } catch let failure as CertificateFailure {
                failures += 1
                guard failures <= 2 else { throw RemoteSSHError.certificateRejected }
                try await trustCertificate(after: failure)
            }
        }
    }

    /// Picks the public key to pin after a verification failure: one trusted before (saved, or accepted on
    /// another connection this run), else the server's current certificate once the user accepts it.
    private func trustCertificate(after failure: CertificateFailure) async throws {
        let site = self.site
        let host = site.host, port = site.effectivePort
        if !failure.pinMismatch, lock.withLock({ pinnedKey }) == nil, let known = pins.pin(host: host, port: port) {
            lock.withLock { pinnedKey = known.publicKeySHA256 }
            return
        }
        let certificate = try await fetchCertificate()
        let known = pins.pin(host: host, port: port)
        if let known, known.publicKeySHA256 == certificate.publicKeySHA256 {
            // Another request of this session (or another connection) got it accepted meanwhile.
        } else if site.trustInvalidCertificate, known == nil {
            // Sites saved with the old "trust any certificate" setting: pin the certificate seen now.
            pins.trust(certificate, host: host, port: port, remember: true)
            log(LogLine(.status, "Pinned the TLS certificate of \(host):\(port) (\(certificate.subject), SHA-256 \(certificate.fingerprint)): the site trusts the server's certificate, and from now on only this one is accepted"))
        } else {
            let answer = await prompter?.confirmCertificate(host: host, port: port, certificate: certificate,
                                                            reason: failure.message, changed: failure.pinMismatch) ?? .reject
            guard answer != .reject else { throw RemoteSSHError.certificateRejected }
            pins.trust(certificate, host: host, port: port, remember: answer == .always)
            log(LogLine(.status, "Certificate trusted by user for \(host):\(port) (SHA-256 \(certificate.fingerprint))"))
        }
        lock.withLock { pinnedKey = certificate.publicKeySHA256 }
    }

    /// The certificate the server presents, read without verification on a throwaway handle that logs in
    /// anonymously (the site's credentials are never sent over the unverified connection).
    private func fetchCertificate() async throws -> CertificatePin {
        try await withCheckedThrowingContinuation { cont in
            queue.async { [self] in
                let h = CurlHandle()
                applyBaseOptions(h, pinning: false)
                h.set(CURLOPT_USERNAME, "anonymous")
                h.set(CURLOPT_PASSWORD, "anonymous@example.com")
                h.set(CURLOPT_SSL_VERIFYPEER, 0)
                h.set(CURLOPT_SSL_VERIFYHOST, 0)
                h.set(CURLOPT_CERTINFO, 1)
                h.set(CURLOPT_URL, baseURL + "/")
                h.set(CURLOPT_NOBODY, 1)
                let ctx = CurlContext()
                ctx.shouldAbort = { [weak self] in self?.isAborted ?? true }
                let code = h.perform(ctx)
                if let pin = h.leafCertificatePEM().flatMap(CertificatePin.init(pem:)) {
                    cont.resume(returning: pin)
                } else {
                    cont.resume(throwing: RemoteSSHError.connectionFailed("Could not read the server's TLS certificate (\(CurlHandle.describe(code)))"))
                }
            }
        }
    }

    private func perform<T>(_ body: @escaping (CurlHandle, CurlContext) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async { [self] in
                guard !isAborted else { return cont.resume(throwing: RemoteSSHError.notConnected) }
                let h = handle ?? CurlHandle()
                handle = h
                h.reset()
                applyBaseOptions(h)
                let ctx = CurlContext()
                ctx.log = log
                ctx.shouldAbort = { [weak self] in self?.isAborted ?? true }
                let result = Result { try body(h, ctx) }
                noteNewConnection(ctx)
                cont.resume(with: result)
            }
        }
    }

    /// A "220" greeting means this request opened a new control connection. Records whether it is
    /// encrypted; once TLS worked, later reconnects require it, so they can't be downgraded to plain FTP.
    private func noteNewConnection(_ ctx: CurlContext) {
        guard ctx.responseLines.contains(where: { $0.hasPrefix("220") }) else { return }
        lock.withLock {
            switch _site.encryption {
            case .plain: tlsActive = false
            case .requireExplicit, .requireImplicit: tlsActive = true
            case .explicitIfAvailable:
                // Only the reply to AUTH TLS (or AUTH SSL) counts: 234 (334) means curl went on to TLS, anything
                // else that it carried on in plain text. A banner line starting with "234" is not that reply.
                tlsActive = ctx.authReply.map { $0.hasPrefix("234") || $0.hasPrefix("334") } ?? false
                if tlsActive { _site.encryption = .requireExplicit }
            }
        }
        if !isEncrypted && site.encryption != .plain {
            log(LogLine(.error, "The server does not support TLS; the connection is not encrypted"))
        }
    }

    private func check(_ code: CURLcode, _ ctx: CurlContext) throws {
        guard code != CURLE_OK else { return }
        let serverMessage = ctx.responseLines.last(where: { $0.count >= 3 && $0.prefix(3).allSatisfy(\.isNumber) && Int($0.prefix(3))! >= 400 })
        let message = serverMessage ?? CurlHandle.describe(code)
        switch code {
        case CURLE_PEER_FAILED_VERIFICATION:
            throw CertificateFailure(message: CurlHandle.describe(code))
        case CURLE_SSL_PINNEDPUBKEYNOTMATCH:
            throw CertificateFailure(message: "The server's certificate is not the one that was trusted before.", pinMismatch: true)
        case CURLE_LOGIN_DENIED:
            throw RemoteSSHError.authenticationFailed(message)
        case CURLE_REMOTE_ACCESS_DENIED:
            throw RemoteSSHError.accessDenied(message)
        case CURLE_REMOTE_FILE_NOT_FOUND:
            throw RemoteSSHError.fileNotFound(message)
        case CURLE_ABORTED_BY_CALLBACK:
            throw RemoteSSHError.cancelled
        case CURLE_COULDNT_CONNECT, CURLE_COULDNT_RESOLVE_HOST, CURLE_OPERATION_TIMEDOUT, CURLE_USE_SSL_FAILED, CURLE_SSL_CONNECT_ERROR:
            throw RemoteSSHError.connectionFailed(CurlHandle.describe(code))
        default:
            throw RemoteSSHError.commandFailed(message)
        }
    }

    // MARK: RemoteSession

    public func connect() async throws {
        lock.withLock { aborted = false }
        log(LogLine(.status, "Connecting to \(site.host):\(site.effectivePort)..."))
        let home = try await homeDirectory()
        log(LogLine(.status, "Logged in. Current directory: \(home)"))
    }

    /// Stops the running request and closes the connection. Returns after at most about two seconds even
    /// when the server is slow to answer; the handle is then freed in the background.
    public func disconnect() async {
        lock.withLock {
            aborted = true
            cachedHome = nil
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let resume = ResumeOnce(cont)
            queue.async { [self] in
                handle = nil  // curl_easy_cleanup: QUIT, close the connection
                resume()
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { resume() }
        }
        log(LogLine(.status, "Disconnected from server"))
    }

    public func homeDirectory() async throws -> String {
        if let cachedHome = lock.withLock({ cachedHome }) { return cachedHome }
        let base = baseURL + "/"
        let home: String = try await run { h, ctx in
            h.set(CURLOPT_URL, base)
            h.set(CURLOPT_NOBODY, 1)
            h.set(CURLOPT_QUOTE, list: ["PWD"])
            try self.check(h.perform(ctx), ctx)
            guard let line = ctx.responseLines.last(where: { $0.hasPrefix("257") }),
                  let first = line.firstIndex(of: "\""), let last = line.lastIndex(of: "\""), first < last
            else { return "/" }
            return String(line[line.index(after: first)..<last]).replacingOccurrences(of: "\"\"", with: "\"")
        }
        lock.withLock { cachedHome = home }
        return home
    }

    public func list(_ path: String) async throws -> [FileEntry] {
        let known = lock.withLock { listCommand }
        let candidates = known.map { [$0] } ?? ["MLSD", "LIST -a", "LIST"]
        var lastError: Error?
        for command in candidates {
            do {
                let text: String = try await run { h, ctx in
                    var data = Data()
                    ctx.onWrite = { buf in data.append(contentsOf: buf); return true }
                    h.set(CURLOPT_URL, self.url(for: path, directory: true))
                    h.set(CURLOPT_CUSTOMREQUEST, command)
                    try self.check(h.perform(ctx), ctx)
                    return String(decoding: data, as: UTF8.self)
                }
                lock.withLock { listCommand = command }
                return ListingParser.parse(text) { name in
                    self.log(LogLine(.error, "Skipped an entry with an invalid file name: \(name.debugDescription)"))
                }
            } catch let error as RemoteSSHError {
                if case .commandFailed = error, known == nil { lastError = error; continue }
                throw error
            }
        }
        throw lastError ?? RemoteSSHError.commandFailed("Failed to retrieve directory listing")
    }

    /// FTP commands end at CR/LF, so a name containing one would smuggle in a second command
    /// (e.g. a rename to "x\r\nDELE important").
    static func validate(_ commands: [String]) throws {
        // Unicode scalars, not Characters: "\r\n" is a single Character that equals neither "\r" nor "\n".
        if commands.contains(where: { $0.unicodeScalars.contains { $0 == "\r" || $0 == "\n" || $0 == "\0" } }) {
            throw RemoteSSHError.invalidInput("File names with line breaks can't be used over FTP.")
        }
    }

    private func quote(_ commands: [String], in directory: String) async throws -> [String] {
        try Self.validate(commands)
        return try await run { h, ctx in
            h.set(CURLOPT_URL, self.url(for: directory, directory: true))
            h.set(CURLOPT_NOBODY, 1)
            h.set(CURLOPT_QUOTE, list: commands)
            try self.check(h.perform(ctx), ctx)
            return ctx.responseLines
        }
    }

    public func makeDirectory(_ path: String) async throws {
        _ = try await quote(["MKD \(path)"], in: RemotePath.parent(of: path))
    }

    public func deleteFile(_ path: String) async throws {
        _ = try await quote(["DELE \(path)"], in: RemotePath.parent(of: path))
    }

    public func removeDirectory(_ path: String) async throws {
        _ = try await quote(["RMD \(path)"], in: RemotePath.parent(of: path))
    }

    public func rename(_ from: String, to: String) async throws {
        _ = try await quote(["RNFR \(from)", "RNTO \(to)"], in: RemotePath.parent(of: from))
    }

    public func chmod(_ path: String, mode: Int) async throws {
        _ = try await quote(["SITE CHMOD \(Permissions.octalString(mode)) \(path)"], in: RemotePath.parent(of: path))
    }

    public func rawCommand(_ command: String) async throws -> String {
        let home = try await homeDirectory()
        let lines = try await quote(["*" + command], in: home)
        return lines.last ?? ""
    }

    /// One SIZE round trip (RFC 3659) instead of listing the whole parent directory;
    /// falls back to a listing for servers without SIZE.
    public func fileSize(_ path: String) async throws -> Int64? {
        let lines = try await quote(["TYPE I", "*SIZE \(path)"], in: RemotePath.parent(of: path))
        // curl may send CWD afterwards, so take the reply that follows the TYPE I acknowledgement.
        let replies = lines.filter { $0.count >= 4 && $0.prefix(3).allSatisfy(\.isNumber) && $0.dropFirst(3).first == " " }
        if let typeAck = replies.lastIndex(where: { $0.hasPrefix("200") }), typeAck + 1 < replies.count {
            let reply = replies[typeAck + 1]
            if reply.hasPrefix("213 "), let size = Int64(reply.dropFirst(4).trimmingCharacters(in: .whitespaces)) { return size }
            if reply.hasPrefix("550") { return nil }
        }
        let name = RemotePath.lastComponent(of: path)
        return try await list(RemotePath.parent(of: path)).first { $0.name == name && !$0.isDirectory }?.size
    }

    public func download(_ remotePath: String, to localURL: URL, resumeFrom offset: Int64, cancel: CancelToken, progress: @escaping ProgressHandler) async throws {
        log(LogLine(.status, "Starting download of \(remotePath)"))
        try await DownloadTarget.write(to: localURL, resumeFrom: offset) { target in
            let file = target.handle
            try await run { h, ctx in
                // A request retried after a certificate prompt starts over at the resume point.
                try file.truncate(atOffset: UInt64(offset))
                var writeError: Error?
                ctx.onWrite = { buf in
                    do { try file.write(contentsOf: Data(buf)); return true } catch { writeError = error; return false }
                }
                ctx.onProgress = { total, now, _, _ in
                    progress(TransferProgress(transferred: offset + now, total: total > 0 ? offset + total : nil))
                    return !cancel.isCancelled
                }
                h.set(CURLOPT_URL, self.url(for: remotePath, directory: false))
                if offset > 0 { h.set(CURLOPT_RESUME_FROM_LARGE, offset: offset) }
                let code = h.perform(ctx)
                if let writeError { throw writeError }
                try self.check(code, ctx)
            }
        }
        log(LogLine(.status, "File transfer successful, transferred \(remotePath)"))
    }

    public func upload(_ localURL: URL, to remotePath: String, resumeFrom offset: Int64, cancel: CancelToken, progress: @escaping ProgressHandler) async throws {
        let file = try FileHandle(forReadingFrom: localURL)
        defer { try? file.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? Int64) ?? 0
        if offset > 0 { try file.seek(toOffset: UInt64(offset)) }

        log(LogLine(.status, "Starting upload of \(localURL.path)"))
        try await run { h, ctx in
            ctx.onRead = { buf in
                guard let data = try? file.read(upToCount: buf.count), !data.isEmpty else { return 0 }
                data.copyBytes(to: buf)
                return data.count
            }
            ctx.onProgress = { _, _, _, now in
                progress(TransferProgress(transferred: offset + now, total: size))
                return !cancel.isCancelled
            }
            h.set(CURLOPT_URL, self.url(for: remotePath, directory: false))
            h.set(CURLOPT_UPLOAD, 1)
            h.set(CURLOPT_INFILESIZE_LARGE, offset: size - offset)
            h.set(CURLOPT_FTP_CREATE_MISSING_DIRS, Int(CURLFTP_CREATE_DIR_RETRY.rawValue))
            if offset > 0 { h.set(CURLOPT_APPEND, 1) }
            try self.check(h.perform(ctx), ctx)
        }
        log(LogLine(.status, "File transfer successful, transferred \(localURL.lastPathComponent)"))
    }
}

/// Resumes a continuation once, whichever of several racing callers comes first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }

    func callAsFunction() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { continuation = nil }
            return continuation
        }
        c?.resume()
    }
}
