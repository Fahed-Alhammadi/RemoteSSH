import Foundation
import Security

/// Site Manager persistence. Site metadata is JSON in Application Support;
/// passwords never touch disk — they live in the macOS Keychain.
public final class SiteStore: @unchecked Sendable {
    private let url: URL

    public init(url: URL = AppPaths.file("sites.json")) {
        self.url = url
    }

    public func load() -> [Site] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([Site].self, from: data)) ?? []
    }

    public func save(_ sites: [Site]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sites).write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
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
