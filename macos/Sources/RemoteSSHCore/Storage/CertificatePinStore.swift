import CryptoKit
import Foundation
import Security

/// A server's TLS certificate as the user saw it in the trust prompt, and the public key that is pinned
/// once they trust it.
public struct CertificatePin: Codable, Equatable, Sendable {
    /// Base64 SHA-256 of the certificate's SubjectPublicKeyInfo: the value curl's `CURLOPT_PINNEDPUBLICKEY`
    /// checks (`sha256//<this>`), on the control connection and on every data connection.
    public var publicKeySHA256: String
    /// SHA-256 of the whole certificate, "AB:CD:…" (as `openssl x509 -fingerprint -sha256` prints it).
    public var fingerprint: String
    public var subject: String

    public init(publicKeySHA256: String, fingerprint: String, subject: String) {
        self.publicKeySHA256 = publicKeySHA256
        self.fingerprint = fingerprint
        self.subject = subject
    }

    /// From a DER-encoded X.509 certificate; nil when it can't be parsed.
    public init?(der: Data) {
        guard let spki = Self.subjectPublicKeyInfo(ofCertificate: der) else { return nil }
        publicKeySHA256 = Data(SHA256.hash(data: spki)).base64EncodedString()
        fingerprint = SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
        if let cert = SecCertificateCreateWithData(nil, der as CFData), let summary = SecCertificateCopySubjectSummary(cert) {
            subject = summary as String
        } else {
            subject = "(unnamed certificate)"
        }
    }

    /// From the first "BEGIN CERTIFICATE" block of a PEM text (curl's certinfo "Cert:" field).
    public init?(pem: String) {
        guard let begin = pem.range(of: "-----BEGIN CERTIFICATE-----"),
              let end = pem.range(of: "-----END CERTIFICATE-----", range: begin.upperBound..<pem.endIndex),
              let der = Data(base64Encoded: String(pem[begin.upperBound..<end.lowerBound].filter { !$0.isWhitespace }))
        else { return nil }
        self.init(der: der)
    }

    /// The DER bytes of the SubjectPublicKeyInfo inside an X.509 certificate:
    /// Certificate ::= SEQUENCE { tbsCertificate SEQUENCE { [0] version OPTIONAL, serialNumber, signature,
    /// issuer, validity, subject, subjectPublicKeyInfo, … }, … }
    static func subjectPublicKeyInfo(ofCertificate der: Data) -> Data? {
        let bytes = [UInt8](der)
        func element(at i: Int) -> (tag: UInt8, content: Range<Int>, end: Int)? {
            guard i >= 0, i + 2 <= bytes.count else { return nil }
            var length = Int(bytes[i + 1])
            var start = i + 2
            if length & 0x80 != 0 {
                let count = length & 0x7F
                guard (1...4).contains(count), start + count <= bytes.count else { return nil }
                length = bytes[start..<start + count].reduce(0) { $0 << 8 | Int($1) }
                start += count
            }
            guard start + length <= bytes.count else { return nil }
            return (bytes[i], start..<start + length, start + length)
        }
        guard let cert = element(at: 0), cert.tag == 0x30,
              let tbs = element(at: cert.content.lowerBound), tbs.tag == 0x30 else { return nil }
        var i = tbs.content.lowerBound
        if let version = element(at: i), version.tag == 0xA0 { i = version.end }
        for _ in 0..<5 {  // serialNumber, signature, issuer, validity, subject
            guard let skipped = element(at: i), skipped.end <= tbs.content.upperBound else { return nil }
            i = skipped.end
        }
        guard let spki = element(at: i), spki.tag == 0x30, spki.end <= tbs.content.upperBound else { return nil }
        return Data(bytes[i..<spki.end])
    }
}

/// Trusted FTPS certificates per server (host:port → pinned public key), kept outside the site file so the
/// `.remotessh` format is unchanged. "Always Trust" is saved; "Connect Once" lasts until the app quits.
/// Shared by every connection to the server (browsing, transfers), so the user is asked once.
public final class CertificatePinStore: @unchecked Sendable {
    private let url: URL?
    private let lock = NSLock()
    private var saved: [String: CertificatePin] = [:]
    private var forThisRun: [String: CertificatePin] = [:]
    private var unreadFile: StoreLoadProblem?

    /// The file could not be read; nothing is written until `allowSaving()`.
    public var loadProblem: StoreLoadProblem? { lock.withLock { unreadFile } }

    /// `url` nil keeps pins in memory only.
    public init(url: URL? = AppPaths.file("certificate_pins.json")) {
        self.url = url
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            saved = try JSONDecoder().decode([String: CertificatePin].self, from: Data(contentsOf: url))
        } catch {
            unreadFile = .make(url, error)
        }
    }

    public func allowSaving() {
        lock.withLock { unreadFile = nil }
    }

    private static func id(_ host: String, _ port: Int) -> String { "[\(host.lowercased())]:\(port)" }

    public func pin(host: String, port: Int) -> CertificatePin? {
        lock.withLock { forThisRun[Self.id(host, port)] ?? saved[Self.id(host, port)] }
    }

    /// Trusts `pin` for the server; `remember` saves it, otherwise it lasts for this run.
    public func trust(_ pin: CertificatePin, host: String, port: Int, remember: Bool) {
        let id = Self.id(host, port)
        update {
            if remember {
                saved[id] = pin
                forThisRun[id] = nil
            } else {
                forThisRun[id] = pin
            }
        }
    }

    public func remove(host: String, port: Int) {
        let id = Self.id(host, port)
        update {
            saved[id] = nil
            forThisRun[id] = nil
        }
    }

    private func update(_ change: () -> Void) {
        lock.lock()
        change()
        let snapshot = saved
        let blocked = unreadFile != nil
        lock.unlock()
        guard let url, !blocked else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
