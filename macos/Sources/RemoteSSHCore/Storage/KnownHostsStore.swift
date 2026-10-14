import CryptoKit
import Foundation

/// Trusted SSH host keys (host:port → OpenSSH public key line).
public final class KnownHostsStore: @unchecked Sendable {
    public enum Status: Equatable { case trusted, unknown, changed }

    private let url: URL
    private let lock = NSLock()
    private var keys: [String: String]

    public init(url: URL = AppPaths.file("known_hosts.json")) {
        self.url = url
        keys = (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
    }

    private static func id(_ host: String, _ port: Int) -> String { "[\(host.lowercased())]:\(port)" }

    public func check(host: String, port: Int, key: String) -> Status {
        lock.lock(); defer { lock.unlock() }
        guard let known = keys[Self.id(host, port)] else { return .unknown }
        return known == key ? .trusted : .changed
    }

    public func trust(host: String, port: Int, key: String) {
        lock.lock()
        keys[Self.id(host, port)] = key
        let snapshot = keys
        lock.unlock()
        try? JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }

    public func remove(host: String, port: Int) {
        lock.lock()
        keys[Self.id(host, port)] = nil
        let snapshot = keys
        lock.unlock()
        try? JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
    }

    /// "SHA256:base64" fingerprint, same format as `ssh-keygen -lf`.
    public static func fingerprint(ofOpenSSHKey key: String) -> String {
        let parts = key.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return "unknown" }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}
