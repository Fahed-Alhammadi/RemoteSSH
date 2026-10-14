import Foundation

/// RemoteSSH's portable site list (`.remotessh` file, JSON) used by
/// File → Export Sites… and File → Import from RemoteSSH….
public struct SiteArchive: Codable, Sendable {
    public static let fileExtension = "remotessh"
    static let formatID = "remotessh.sites"

    public var format = SiteArchive.formatID
    public var version = 1
    public var exportedAt = Date()
    public var sites: [Site]
    /// Plain-text passwords keyed by site id (UUID string); only present when the user opted in.
    /// String keys keep the JSON an object, so the Windows/Linux app reads the same file.
    public var passwords: [String: String]?

    public init(sites: [Site], passwords: [UUID: String]? = nil) {
        self.sites = sites
        self.passwords = passwords.map { Dictionary(uniqueKeysWithValues: $0.map { ($0.key.uuidString, $0.value) }) }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> SiteArchive {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive: SiteArchive
        do {
            archive = try decoder.decode(SiteArchive.self, from: data)
        } catch {
            throw RemoteSSHError.invalidInput("This file is not a RemoteSSH site export.")
        }
        guard archive.format == formatID else {
            throw RemoteSSHError.invalidInput("This file is not a RemoteSSH site export.")
        }
        guard archive.version <= 1 else {
            throw RemoteSSHError.invalidInput("This file was exported by a newer version of RemoteSSH.")
        }
        return archive
    }

    /// Sites ready to be merged into an existing list: every site gets a fresh id so
    /// importing the same file twice never collides, and passwords follow their site.
    public func importable() -> (sites: [Site], passwords: [UUID: String]) {
        var newSites: [Site] = []
        var newPasswords: [UUID: String] = [:]
        for var site in sites {
            let oldID = site.id
            site.id = UUID()
            if let pw = passwords?[oldID.uuidString] ?? passwords?[oldID.uuidString.lowercased()] { newPasswords[site.id] = pw }
            newSites.append(site)
        }
        return (newSites, newPasswords)
    }
}
