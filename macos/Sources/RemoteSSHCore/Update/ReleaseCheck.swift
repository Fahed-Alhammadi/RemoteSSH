import Foundation

/// The newest published GitHub release and its macOS download.
public struct ReleaseInfo: Equatable, Sendable {
    public var version: String
    public var pageURL: URL
    /// The `*-macos.zip` asset, if the release has one.
    public var downloadURL: URL?
    /// Lowercase hex SHA-256 of the asset, when GitHub reports one.
    public var sha256: String?
}

/// Looks up the newest macOS release of the project's GitHub repository. Each platform is released under
/// its own tag (`macos-v1.2.0`, `windows-v1.2.0`, `linux-v1.2.0`); drafts and pre-releases are skipped.
public enum ReleaseCheck {
    public static let repository = "Fahed-Alhammadi/RemoteSSH"
    public static let tagPrefix = "macos-v"

    public enum CheckError: LocalizedError {
        case http(Int)
        case malformed
        public var errorDescription: String? {
            switch self {
            case .http(let code): "GitHub returned HTTP \(code)."
            case .malformed: "GitHub returned an unexpected response."
            }
        }
    }

    /// The newest macOS release, or nil when none has been published yet.
    public static func latest(session: URLSession = .shared) async throws -> ReleaseInfo? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=100")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("RemoteSSH", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw CheckError.http(status) }
        return try parse(data)
    }

    /// Picks the newest published `macos-v*` release from a GitHub release list.
    public static func parse(_ data: Data) throws -> ReleaseInfo? {
        struct Asset: Decodable { let name: String; let browser_download_url: URL; let digest: String? }
        struct Release: Decodable {
            let tag_name: String; let html_url: URL; let draft: Bool; let prerelease: Bool; let assets: [Asset]
        }
        guard let releases = try? JSONDecoder().decode([Release].self, from: data) else { throw CheckError.malformed }
        let newest = releases
            .filter { !$0.draft && !$0.prerelease && $0.tag_name.hasPrefix(tagPrefix) }
            .max { compare(String($0.tag_name.dropFirst(tagPrefix.count)), String($1.tag_name.dropFirst(tagPrefix.count))) == .orderedAscending }
        guard let release = newest else { return nil }
        let asset = release.assets.first { $0.name.hasSuffix("-macos.zip") }
        let digest = asset?.digest.flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)).lowercased() : nil }
        let version = String(release.tag_name.dropFirst(tagPrefix.count))
        return ReleaseInfo(version: version, pageURL: release.html_url, downloadURL: asset?.browser_download_url, sha256: digest)
    }

    /// Compares dotted versions numerically ("1.2.10" > "1.2.9"); a leading "v" and suffixes are ignored.
    public static func compare(_ a: String, _ b: String) -> ComparisonResult {
        func parts(_ v: String) -> [Int] {
            let core = (v.hasPrefix("v") ? v.dropFirst() : Substring(v)).split(whereSeparator: { $0 == "-" || $0 == "+" }).first ?? ""
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
