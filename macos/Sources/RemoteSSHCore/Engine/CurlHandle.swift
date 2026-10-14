import CCurl
import Foundation

private let curlGlobalInit: Void = {
    curl_global_init(Int(CURL_GLOBAL_DEFAULT))
}()

/// Per-request callback context, passed to C callbacks through an unmanaged pointer.
final class CurlContext {
    var onWrite: ((UnsafeRawBufferPointer) -> Bool)?
    var onRead: ((UnsafeMutableRawBufferPointer) -> Int)?
    var onHeader: ((String) -> Void)?
    var onProgress: ((Int64, Int64, Int64, Int64) -> Bool)?
    var log: LogSink?
    var responseLines: [String] = []
}

/// Owns one CURL easy handle. curl keeps the control connection alive inside the handle,
/// so reusing it for consecutive operations reuses the FTP session.
/// Not thread safe: callers serialise access (FTPSession uses a serial queue).
final class CurlHandle {
    let raw: UnsafeMutableRawPointer
    private var slists: [UnsafeMutablePointer<curl_slist>] = []

    init() {
        _ = curlGlobalInit
        raw = curl_easy_init()
    }

    deinit {
        freeLists()
        curl_easy_cleanup(raw)
    }

    func reset() {
        freeLists()
        curl_easy_reset(raw)
    }

    private func freeLists() {
        for l in slists { curl_slist_free_all(l) }
        slists.removeAll()
    }

    func set(_ opt: CURLoption, _ value: Int) { ccurl_setopt_long(raw, opt, value) }
    func set(_ opt: CURLoption, offset value: Int64) { ccurl_setopt_off(raw, opt, curl_off_t(value)) }
    func set(_ opt: CURLoption, _ value: String) { ccurl_setopt_str(raw, opt, value) }  // libcurl copies strings
    func set(_ opt: CURLoption, list: [String]) {
        var l: UnsafeMutablePointer<curl_slist>?
        for item in list { l = curl_slist_append(l, item) }
        if let l { slists.append(l) }
        ccurl_setopt_slist(raw, opt, l)
    }

    /// Runs curl_easy_perform with callbacks bound to `context`. Blocking.
    func perform(_ context: CurlContext) -> CURLcode {
        let ptr = Unmanaged.passUnretained(context).toOpaque()
        if context.onWrite != nil {
            ccurl_set_write(raw, { data, size, n, ud in
                let ctx = Unmanaged<CurlContext>.fromOpaque(ud!).takeUnretainedValue()
                let count = size * n
                let ok = ctx.onWrite?(UnsafeRawBufferPointer(start: data, count: count)) ?? true
                return ok ? count : 0
            }, ptr)
        } else {
            // discard bodies (e.g. NOBODY quote requests)
            ccurl_set_write(raw, { _, size, n, _ in size * n }, ptr)
        }
        if context.onRead != nil {
            ccurl_set_read(raw, { data, size, n, ud in
                let ctx = Unmanaged<CurlContext>.fromOpaque(ud!).takeUnretainedValue()
                let r = ctx.onRead?(UnsafeMutableRawBufferPointer(start: data, count: size * n)) ?? 0
                return r < 0 ? Int(CURL_READFUNC_ABORT) : r
            }, ptr)
        }
        ccurl_set_header(raw, { data, size, n, ud in
            let ctx = Unmanaged<CurlContext>.fromOpaque(ud!).takeUnretainedValue()
            let count = size * n
            if let data, let line = String(bytes: UnsafeRawBufferPointer(start: data, count: count), encoding: .utf8) {
                let trimmed = line.trimmingCharacters(in: .newlines)
                ctx.responseLines.append(trimmed)
                ctx.onHeader?(trimmed)
            }
            return count
        }, ptr)
        if context.onProgress != nil {
            ccurl_set_xferinfo(raw, { ud, dt, dn, ut, un in
                let ctx = Unmanaged<CurlContext>.fromOpaque(ud!).takeUnretainedValue()
                return (ctx.onProgress?(Int64(dt), Int64(dn), Int64(ut), Int64(un)) ?? true) ? 0 : 1
            }, ptr)
        }
        if context.log != nil {
            ccurl_set_debug(raw, { _, type, data, size, ud in
                let ctx = Unmanaged<CurlContext>.fromOpaque(ud!).takeUnretainedValue()
                guard let data, let text = String(bytes: UnsafeRawBufferPointer(start: data, count: size), encoding: .utf8) else { return 0 }
                for line in text.split(whereSeparator: \.isNewline) {
                    let l = String(line)
                    switch type {
                    case CURLINFO_HEADER_OUT:
                        let masked = l.uppercased().hasPrefix("PASS ") ? "PASS ****" : l
                        ctx.log?(LogLine(.command, masked))
                    case CURLINFO_HEADER_IN:
                        ctx.log?(LogLine(.response, l))
                    case CURLINFO_TEXT:
                        ctx.log?(LogLine(.trace, l))
                    default:
                        break
                    }
                }
                return 0
            }, ptr)
        }
        return curl_easy_perform(raw)
    }

    var responseCode: Int { ccurl_response_code(raw) }

    static func describe(_ code: CURLcode) -> String {
        String(cString: curl_easy_strerror(code))
    }
}
