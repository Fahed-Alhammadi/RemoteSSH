import CCurl
import Foundation

/// FTP / FTPS (explicit + implicit) session backed by the system libcurl.
/// One instance = one control connection; the transfer queue creates a separate session per
/// concurrent transfer.
public final class FTPSession: RemoteSession, @unchecked Sendable {
    public private(set) var site: Site
    private let credentials: SessionCredentials
    private let options: SessionOptions
    private weak var prompter: SessionPrompter?
    private let log: LogSink
    private let queue: DispatchQueue
    private let handle = CurlHandle()
    private var listCommand: String?
    private var cachedHome: String?

    init(site: Site, credentials: SessionCredentials, options: SessionOptions, prompter: SessionPrompter?, log: @escaping LogSink) {
        self.site = site
        self.credentials = credentials
        self.options = options
        self.prompter = prompter
        self.log = log
        self.queue = DispatchQueue(label: "remotessh.ftp.\(site.host)")
    }

    // MARK: URL building

    private var baseURL: String {
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
        h.set(CURLOPT_USERNAME, site.effectiveUser.isEmpty ? "anonymous" : site.effectiveUser)
        h.set(CURLOPT_PASSWORD, site.logonType == .anonymous ? "anonymous@example.com" : credentials.password)
        h.set(CURLOPT_CONNECTTIMEOUT, options.connectTimeout)
        h.set(CURLOPT_SERVER_RESPONSE_TIMEOUT, 60)
        h.set(CURLOPT_LOW_SPEED_LIMIT, 1)
        h.set(CURLOPT_LOW_SPEED_TIME, 120)
        h.set(CURLOPT_TCP_KEEPALIVE, options.keepAlive ? 1 : 0)
        h.set(CURLOPT_FTP_FILEMETHOD, Int(CURLFTPMETHOD_SINGLECWD.rawValue))
        h.set(CURLOPT_FTP_USE_EPSV, 1)
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
            site.trustInvalidCertificate = true
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
                do {
                    cont.resume(returning: try body(handle, ctx))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func check(_ code: CURLcode, _ ctx: CurlContext) throws {
        guard code != CURLE_OK else { return }
        let serverMessage = ctx.responseLines.last(where: { $0.count >= 3 && $0.prefix(3).allSatisfy(\.isNumber) && Int($0.prefix(3))! >= 400 })
        let message = serverMessage ?? CurlHandle.describe(code)
        switch code {
        case CURLE_PEER_FAILED_VERIFICATION, CURLE_SSL_CERTPROBLEM:
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
        if let cachedHome { return cachedHome }
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
        cachedHome = home
        return home
    }

    public func list(_ path: String) async throws -> [FileEntry] {
        let candidates = listCommand.map { [$0] } ?? ["MLSD", "LIST -a", "LIST"]
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
                listCommand = command
                return ListingParser.parse(text)
            } catch let error as RemoteSSHError {
                if case .commandFailed = error, listCommand == nil { lastError = error; continue }
                throw error
            }
        }
        throw lastError ?? RemoteSSHError.commandFailed("Failed to retrieve directory listing")
    }

    private func quote(_ commands: [String], in directory: String) async throws -> [String] {
        try await run { h, ctx in
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
