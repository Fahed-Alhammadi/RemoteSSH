import Foundation
import Security

/// Site Manager persistence. Site metadata is JSON in Application Support;
/// passwords never touch disk — they live in the macOS Keychain.
public final class SiteStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    /// Set when the file could not be read in full: saving would replace it with the sites that loaded.
    private var unreadFile: StoreLoadProblem?

    public init(url: URL = AppPaths.file("sites.json")) {
        self.url = url
    }

    /// The saved sites. When the file exists but can't be read in full, the readable sites are returned
    /// with a `problem`, the file is backed up, and `save` refuses to overwrite it until `allowSaving()`.
    public func load() -> (sites: [Site], problem: StoreLoadProblem?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([], nil) }
        let result: (sites: [Site], problem: StoreLoadProblem?)
        do {
            let entries = try JSONDecoder().decode([LossySite].self, from: Data(contentsOf: url))
            let sites = entries.compactMap(\.site)
            let skipped = entries.count - sites.count
            result = (sites, skipped == 0 ? nil : .make(url, nil, detail: "\(skipped) site\(skipped == 1 ? "" : "s") could not be read"))
        } catch {
            result = ([], .make(url, error))
        }
        lock.withLock { unreadFile = result.problem }
        return result
    }

    /// Call once the user has been told about the load problem; the next save replaces the file.
    public func allowSaving() {
        lock.withLock { unreadFile = nil }
    }

    public func save(_ sites: [Site]) throws {
        if let problem = lock.withLock({ unreadFile }) { throw problem }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sites).write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// One element of the site list; a site that fails to decode becomes nil instead of failing the whole list.
private struct LossySite: Decodable {
    let site: Site?
    init(from decoder: Decoder) throws { site = try? Site(from: decoder) }
}

public enum Keychain {
    private static let service = "RemoteSSH"

    public static func password(for siteID: UUID) -> String? {
        read(service: service, account: siteID.uuidString)
    }

    @discardableResult
    public static func setPassword(_ password: String?, for siteID: UUID) -> Bool {
        delete(service: service, account: siteID.uuidString)
        guard let password, !password.isEmpty else { return true }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: siteID.uuidString,
            kSecValueData as String: Data(password.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrLabel as String: "RemoteSSH site password",
        ]
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

public enum AppPaths {
    /// ~/Library/Application Support/RemoteSSH
    public static let supportDirectory: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("RemoteSSH", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    public static func file(_ name: String) -> URL {
        supportDirectory.appendingPathComponent(name)
    }
}
