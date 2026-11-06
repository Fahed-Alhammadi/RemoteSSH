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
    private let queue: DispatchQueue
    private let handle = CurlHandle()
    /// Guards the mutable state below: operations on one session can run concurrently (browsing
    /// while a folder is being queued), and the curl queue reads `site` while callers update it.
    private let lock = NSLock()
    private var _site: Site
    private var listCommand: String?
    private var cachedHome: String?
    private var tlsActive = false

    public var site: Site { lock.withLock { _site } }

    /// Whether the control connection is encrypted. With "explicit TLS if available" this is only
    /// known after `connect()`: a server without AUTH TLS falls back to plain FTP.
    public var isEncrypted: Bool { lock.withLock { tlsActive } }

    init(site: Site, credentials: SessionCredentials, options: SessionOptions, prompter: SessionPrompter?, log: @escaping LogSink) {
        self._site = site
        self.credentials = credentials
        self.options = options
        self.prompter = prompter
        self.log = log
        self.queue = DispatchQueue(label: "remotessh.ftp.\(site.host)")
    }

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

    private func applyBaseOptions(_ h: CurlHandle) {
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
        if site.trustInvalidCertificate {
            h.set(CURLOPT_SSL_VERIFYPEER, 0)
            h.set(CURLOPT_SSL_VERIFYHOST, 0)
        }
        if options.downloadLimit > 0 { h.set(CURLOPT_MAX_RECV_SPEED_LARGE, offset: Int64(options.downloadLimit)) }
        if options.uploadLimit > 0 { h.set(CURLOPT_MAX_SEND_SPEED_LARGE, offset: Int64(options.uploadLimit)) }
    }

    private struct CertificateFailure: Error { let message: String }

    /// Runs a curl operation on the session queue. Handles the "untrusted certificate" prompt
    /// and retries once if the user accepts it.
    private func run<T>(_ body: @escaping (CurlHandle, CurlContext) throws -> T) async throws -> T {
        do {
            return try await perform(body)
        } catch let failure as CertificateFailure {
            let accepted = await prompter?.confirmCertificate(host: site.host, port: site.effectivePort, reason: failure.message) ?? false
            guard accepted else { throw RemoteSSHError.certificateRejected }
            lock.withLock { _site.trustInvalidCertificate = true }
            log(LogLine(.status, "Certificate accepted by user for \(site.host)"))
            return try await perform(body)
        }
    }

    private func perform<T>(_ body: @escaping (CurlHandle, CurlContext) throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            queue.async { [self] in
                handle.reset()
                applyBaseOptions(handle)
                let ctx = CurlContext()
                ctx.log = log
                let result = Result { try body(handle, ctx) }
                noteNewConnection(ctx.responseLines)
                cont.resume(with: result)
            }
        }
    }

    /// A "220" greeting means this request opened a new control connection. Records whether it is
    /// encrypted; once TLS worked, later reconnects require it, so they can't be downgraded to plain FTP.
    private func noteNewConnection(_ replies: [String]) {
        guard replies.contains(where: { $0.hasPrefix("220") }) else { return }
        lock.withLock {
            switch _site.encryption {
            case .plain: tlsActive = false
            case .requireExplicit, .requireImplicit: tlsActive = true
            case .explicitIfAvailable:
                // 234 (or 334 for AUTH SSL) accepts the AUTH command; without it curl carries on in plain text.
                tlsActive = replies.contains { $0.hasPrefix("234") || $0.hasPrefix("334") }
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
        case CURLE_LOGIN_DENIED:
            throw RemoteSSHError.authenticationFailed(message)
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
        log(LogLine(.status, "Connecting to \(site.host):\(site.effectivePort)..."))
        let home = try await homeDirectory()
        log(LogLine(.status, "Logged in. Current directory: \(home)"))
    }

    public func disconnect() async {
        await withCheckedContinuation { cont in
            queue.async { [self] in
                handle.reset()  // connection stays cached until the handle is freed
                cont.resume()
            }
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
        let fm = FileManager.default
        if offset == 0 || !fm.fileExists(atPath: localURL.path) {
            fm.createFile(atPath: localURL.path, contents: nil)
        }
        let file = try FileHandle(forWritingTo: localURL)
        defer { try? file.close() }
        if offset > 0 { try file.seekToEnd() } else { try file.truncate(atOffset: 0) }

        log(LogLine(.status, "Starting download of \(remotePath)"))
        try await run { h, ctx in
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
