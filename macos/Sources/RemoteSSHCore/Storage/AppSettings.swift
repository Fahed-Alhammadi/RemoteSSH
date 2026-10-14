import Foundation

/// Preferences (RemoteSSH → Settings).
public struct AppSettings: Codable, Equatable, Sendable {
    public var maxConcurrentTransfers = 2
    public var defaultOverwriteDownload: OverwriteAction = .ask
    public var defaultOverwriteUpload: OverwriteAction = .ask
    public var showHiddenFiles = true
    /// KiB/s, 0 = unlimited.
    public var downloadLimitKiB = 0
    public var uploadLimitKiB = 0
    public var connectTimeout = 20
    public var keepAlive = true
    public var retryCount = 2
    public var showDirectoryComparison = true

    public init() {}

    private static let key = "RemoteSSH.settings"

    public static func load(_ defaults: UserDefaults = .standard) -> AppSettings {
        guard let data = defaults.data(forKey: key), let s = try? JSONDecoder().decode(AppSettings.self, from: data) else { return AppSettings() }
        return s
    }

    public func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }

    public var sessionOptions: SessionOptions {
        var o = SessionOptions()
        o.connectTimeout = connectTimeout
        o.keepAlive = keepAlive
        o.downloadLimit = downloadLimitKiB * 1024
        o.uploadLimit = uploadLimitKiB * 1024
        return o
    }
}
