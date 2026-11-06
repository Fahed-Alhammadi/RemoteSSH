import CryptoKit
import Foundation

/// Trusted SSH host keys (host:port → OpenSSH public key line).
public final class KnownHostsStore: @unchecked Sendable {
    public enum Status: Equatable { case trusted, unknown, changed }

    private let url: URL
    private let lock = NSLock()
    private var keys: [String: String] = [:]
    /// Set when the file exists but could not be read; writes are held back (trust still works for this
    /// run) until `allowSaving()`, so the unreadable file isn't replaced before the user knows.
    public var loadProblem: StoreLoadProblem? { lock.withLock { unreadFile } }
    private var unreadFile: StoreLoadProblem?

    public init(url: URL = AppPaths.file("known_hosts.json")) {
        self.url = url
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            keys = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        } catch {
            unreadFile = .make(url, error)
        }
    }

    /// Call once the user has been told about `loadProblem`; the next change rewrites the file.
    public func allowSaving() {
        lock.withLock { unreadFile = nil }
    }

    private static func id(_ host: String, _ port: Int) -> String { "[\(host.lowercased())]:\(port)" }

    public func check(host: String, port: Int, key: String) -> Status {
        lock.lock(); defer { lock.unlock() }
        guard let known = keys[Self.id(host, port)] else { return .unknown }
        return known == key ? .trusted : .changed
    }

    public func trust(host: String, port: Int, key: String) {
        update { $0[Self.id(host, port)] = key }
    }

    public func remove(host: String, port: Int) {
        update { $0[Self.id(host, port)] = nil }
    }

    private func update(_ change: (inout [String: String]) -> Void) {
        lock.lock()
        change(&keys)
        let snapshot = keys
        let blocked = unreadFile != nil
        lock.unlock()
        guard !blocked, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// "SHA256:base64" fingerprint, same format as `ssh-keygen -lf`.
    public static func fingerprint(ofOpenSSHKey key: String) -> String {
        let parts = key.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return "unknown" }
        let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
        return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }
}
