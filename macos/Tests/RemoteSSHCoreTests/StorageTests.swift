import Foundation
import Testing
@testable import RemoteSSHCore

private func tempURL(_ name: String) -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rssh-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent(name)
}

@Suite struct TerminalInputTests {
    @Test func detectsControlCharacters() {
        for bad in ["/tmp/a\u{15}b", "/tmp/\u{03}", "x\u{1b}[2J", "x\ny", "x\ry", "tab\there", "del\u{7F}", "csi\u{9B}31m", "nel\u{85}", "nul\0"] {
            #expect(containsControlCharacters(bad), "\(bad.debugDescription)")
            #expect(changeDirectoryCommand(bad) == nil)
        }
        for good in ["/var/www", "/srv/my folder", "/tmp/it's", "/Users/ü/日本", "/a\u{A0}b", "$(rm -rf ~)"] {
            #expect(!containsControlCharacters(good), "\(good.debugDescription)")
        }
        #expect(changeDirectoryCommand("/srv/it's") == " cd -- '/srv/it'\\''s'")
    }
}

@Suite struct SiteDecodingTests {
    @Test func missingOptionalKeysUseDefaults() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","host":"ftp.example.com","serverProtocol":"ftp"}"#
        let site = try JSONDecoder().decode(Site.self, from: Data(json.utf8))
        #expect(site.id == id)
        #expect(site.host == "ftp.example.com")
        #expect(site.serverProtocol == .ftp)
        #expect(site.encryption == .explicitIfAvailable)
        #expect(site.logonType == .normal)
        #expect(site.transferMode == .passive)
        #expect(site.port == 0)
        #expect(site.name == "New site")
        #expect(!site.trustInvalidCertificate)
    }

    @Test func unknownValuesFallBack() throws {
        let json = #"{"id":"\#(UUID().uuidString)","encryption":"quantumTLS","logonType":"passkey","transferMode":"warp","port":"x","futureField":1}"#
        let site = try JSONDecoder().decode(Site.self, from: Data(json.utf8))
        #expect(site.encryption == .requireExplicit)  // never weaker than TLS
        #expect(site.logonType == .normal)
        #expect(site.transferMode == .passive)
        #expect(site.port == 0)
    }

    @Test func idIsRequired() {
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Site.self, from: Data(#"{"host":"h"}"#.utf8)) }
    }

    @Test func encodingIsUnchanged() throws {
        let site = Site(name: "n", folder: "f", host: "h", port: 2222, serverProtocol: .sftp, logonType: .keyFile, user: "u", keyFilePath: "~/.ssh/k")
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(site)) as? [String: Any])
        #expect(Set(object.keys) == ["id", "name", "folder", "host", "port", "serverProtocol", "encryption", "logonType", "user",
                                     "keyFilePath", "transferMode", "defaultLocalDirectory", "defaultRemoteDirectory", "comments",
                                     "trustInvalidCertificate"])
        #expect(try JSONDecoder().decode(Site.self, from: JSONEncoder().encode(site)) == site)
    }
}

@Suite struct SiteStoreTests {
    @Test func unreadableFileIsKeptAndNotOverwritten() throws {
        let url = tempURL("sites.json")
        let garbage = Data("{not json".utf8)
        try garbage.write(to: url)
        let store = SiteStore(url: url)
        let loaded = store.load()
        #expect(loaded.sites.isEmpty)
        let problem = try #require(loaded.problem)
        #expect(try Data(contentsOf: #require(problem.backup)) == garbage)
        #expect(throws: StoreLoadProblem.self) { try store.save([Site(host: "new")]) }
        #expect(try Data(contentsOf: url) == garbage)

        // Once the user has been told, saving replaces the file.
        store.allowSaving()
        try store.save([Site(host: "new")])
        #expect(SiteStore(url: url).load().sites.map(\.host) == ["new"])
    }

    @Test func badSiteIsSkippedNotEverything() throws {
        let url = tempURL("sites.json")
        let good = Site(host: "good.example.com")
        let list = "[\(String(decoding: try JSONEncoder().encode(good), as: UTF8.self)), {\"host\":\"no id\"}]"
        try Data(list.utf8).write(to: url)
        let store = SiteStore(url: url)
        let loaded = store.load()
        #expect(loaded.sites == [good])
        #expect(loaded.problem != nil)
        #expect(throws: StoreLoadProblem.self) { try store.save(loaded.sites) }
    }

    @Test func existingBackupIsNotReplaced() throws {
        let url = tempURL("sites.json")
        let older = Data("older backup".utf8)
        try older.write(to: url.appendingPathExtension("bak"))
        try Data("broken".utf8).write(to: url)
        let problem = try #require(SiteStore(url: url).load().problem)
        #expect(try Data(contentsOf: url.appendingPathExtension("bak")) == older)
        let backup = try #require(problem.backup)
        #expect(backup != url.appendingPathExtension("bak"))
        #expect(try Data(contentsOf: backup) == Data("broken".utf8))
    }

    @Test func missingFileIsNotAProblem() {
        let loaded = SiteStore(url: tempURL("sites.json")).load()
        #expect(loaded.sites.isEmpty && loaded.problem == nil)
    }
}

@Suite struct KnownHostsTests {
    static let keyA = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
    static let keyB = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHdbGsN5QWBGjmHgk1Q3fEtCq0y8b6m2RYbRwzKUbzKa"

    @Test func trustReloadChangeRemove() {
        let url = tempURL("known_hosts.json")
        let store = KnownHostsStore(url: url)
        #expect(store.check(host: "Example.com", port: 22, key: Self.keyA) == .unknown)
        store.trust(host: "Example.com", port: 22, key: Self.keyA)
        store.trust(host: "example.com", port: 2222, key: Self.keyB)

        let reloaded = KnownHostsStore(url: url)
        #expect(reloaded.check(host: "example.com", port: 22, key: Self.keyA) == .trusted)
        #expect(reloaded.check(host: "EXAMPLE.COM", port: 2222, key: Self.keyB) == .trusted)
        // Ports are kept apart: the key of one port is "changed" on the other.
        #expect(reloaded.check(host: "example.com", port: 22, key: Self.keyB) == .changed)
        #expect(reloaded.check(host: "example.com", port: 2222, key: Self.keyA) == .changed)

        reloaded.remove(host: "example.com", port: 22)
        let after = KnownHostsStore(url: url)
        #expect(after.check(host: "example.com", port: 22, key: Self.keyA) == .unknown)
        #expect(after.check(host: "example.com", port: 2222, key: Self.keyB) == .trusted)
    }

    @Test func unreadableFileIsKept() throws {
        let url = tempURL("known_hosts.json")
        try Data("[".utf8).write(to: url)
        let store = KnownHostsStore(url: url)
        #expect(store.loadProblem?.backup != nil)
        store.trust(host: "h", port: 22, key: Self.keyA)
        #expect(store.check(host: "h", port: 22, key: Self.keyA) == .trusted)  // works for this run
        #expect(try Data(contentsOf: url) == Data("[".utf8))                   // but the file is untouched
        store.allowSaving()
        store.trust(host: "h", port: 22, key: Self.keyA)
        #expect(KnownHostsStore(url: url).check(host: "h", port: 22, key: Self.keyA) == .trusted)
    }

    @Test func fingerprintMatchesSSHKeygen() {
        // `ssh-keygen -lf` on this key prints: 256 SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU (ED25519)
        #expect(KnownHostsStore.fingerprint(ofOpenSSHKey: Self.keyA) == "SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU")
        #expect(KnownHostsStore.fingerprint(ofOpenSSHKey: "garbage") == "unknown")
    }
}

@Suite struct SiteArchiveImportTests {
    private func archive(version: Int = 1, sites: String, passwords: String? = nil) -> Data {
        let pw = passwords.map { #","passwords":\#($0)"# } ?? ""
        return Data(#"{"format":"remotessh.sites","version":\#(version),"exportedAt":"2026-01-01T00:00:00Z","sites":\#(sites)\#(pw)}"#.utf8)
    }

    @Test func newerVersionIsRejected() {
        #expect(throws: RemoteSSHError.self) { try SiteArchive.decode(archive(version: 2, sites: "[]")) }
    }

    @Test func lowercasePasswordKeysAreImported() throws {
        let id = UUID()
        let data = archive(sites: #"[{"id":"\#(id.uuidString)","host":"h"}]"#, passwords: #"{"\#(id.uuidString.lowercased())":"pw"}"#)
        let imported = try SiteArchive.decode(data).importable()
        #expect(imported.passwords[imported.sites[0].id] == "pw")
    }

    @Test func unknownEnumValueIsHandled() throws {
        let data = archive(sites: #"[{"id":"\#(UUID().uuidString)","host":"h","serverProtocol":"ftp","encryption":"tls2030","logonType":"webauthn"}]"#)
        let site = try #require(SiteArchive.decode(data).importable().sites.first)
        #expect(site.serverProtocol == .ftp)
        #expect(site.encryption == .requireExplicit)
        #expect(site.logonType == .normal)
    }

    @Test func certificateTrustIsNotImported() throws {
        let data = try SiteArchive(sites: [Site(host: "h", serverProtocol: .ftp, trustInvalidCertificate: true)]).encoded()
        #expect(try SiteArchive.decode(data).importable().sites.allSatisfy { !$0.trustInvalidCertificate })
    }
}

@Suite struct CertificatePinTests {
    /// Throwaway self-signed X.509 v3 certificate (private key discarded). Expected values from
    /// `openssl x509 -pubkey | openssl pkey -pubin -outform der | openssl dgst -sha256 -binary | base64`
    /// and `openssl x509 -fingerprint -sha256`.
    static let v3 = """
    -----BEGIN CERTIFICATE-----
    MIIBPDCB46ADAgECAgkA1VOYBLKEu9MwCgYIKoZIzj0EAwIwGjEYMBYGA1UEAwwP
    djMuZXhhbXBsZS50ZXN0MCAXDTI2MTEwNjA5Mzc1MloYDzIxMjYxMDEzMDkzNzUy
    WjAaMRgwFgYDVQQDDA92My5leGFtcGxlLnRlc3QwWTATBgcqhkjOPQIBBggqhkjO
    PQMBBwNCAASP53FF+pvnSbal2EgPRDZ7q055eht3qQOk8cpzfr8N27K/rTGpXxcE
    MisVjqTbTP9VsF9ogegM9Q6SAHnhhpjvoxAwDjAMBgNVHRMBAf8EAjAAMAoGCCqG
    SM49BAMCA0gAMEUCIBzinzLZhFn3QMu28jHikAGOCDj3IsTnjo/cbYGgqb+DAiEA
    zdMmA6eUDrNe49Dep5dn+zMNTT2Q/j9fDjnfwIfyokE=
    -----END CERTIFICATE-----
    """

    /// The same for an X.509 v1 certificate (no version field) with explicit curve parameters.
    static let v1 = """
    -----BEGIN CERTIFICATE-----
    MIICIjCCAcgCCQD26mf3EY1sMzAKBggqhkjOPQQDAjAeMRwwGgYDVQQDDBNwaW5u
    ZWQuZXhhbXBsZS50ZXN0MCAXDTI2MTEwNjA5Mzc0MloYDzIxMjYxMDEzMDkzNzQy
    WjAeMRwwGgYDVQQDDBNwaW5uZWQuZXhhbXBsZS50ZXN0MIIBSzCCAQMGByqGSM49
    AgEwgfcCAQEwLAYHKoZIzj0BAQIhAP////8AAAABAAAAAAAAAAAAAAAA////////
    ////////MFsEIP////8AAAABAAAAAAAAAAAAAAAA///////////////8BCBaxjXY
    qjqT57PrvVV2mIa8ZR0GsMxTsPY7zjw+J9JgSwMVAMSdNgiG5wSTamZ44ROdJreB
    n36QBEEEaxfR8uEsQkf4vOblY6RA8ncDfYEt6zOg9KE5RdiYwpZP40Li/hp/m47n
    60p8D54WK84zV2sxXs7LtkBoN79R9QIhAP////8AAAAA//////////+85vqtpxee
    hPO5ysL8YyVRAgEBA0IABA6ifYwSa6FRVqrKt0sxyBB+Hf4CoszhaEKy9RGThPMn
    Izw9iWZRsOiwMf6pkWsdzjdCWjXm8Z1OoB5KG7iVe9swCgYIKoZIzj0EAwIDSAAw
    RQIhAJaVEUVnJsKZSvD1J68kh04/Ho7NPlasSmt5kz8qY+WnAiBTxZJ0nGNXC8/5
    +04bTXqOC2ATArDa4MEHQbNpm779cQ==
    -----END CERTIFICATE-----
    """

    @Test func pinMatchesOpenSSL() throws {
        let pin = try #require(CertificatePin(pem: "Cert:" + Self.v3))
        #expect(pin.publicKeySHA256 == "a3LxHo4XZDDPQjtJKNHO1lewFFNxllGZ8BknwyOoWG8=")
        #expect(pin.fingerprint == "25:6A:B1:AA:15:4C:56:96:05:B6:C6:7D:F1:C3:BE:3F:AD:79:0E:A3:66:E5:18:37:58:CE:8E:44:81:E0:DF:F6")
        #expect(pin.subject == "v3.example.test")

        let old = try #require(CertificatePin(pem: Self.v1))
        #expect(old.publicKeySHA256 == "ffO7CemELAlA2EPyBWRxeeLyDLpvbWH8UQMrBuafCiY=")
        #expect(old.fingerprint.hasPrefix("1A:5C:49:88:A3:D1:B5:63"))
    }

    @Test func rejectsGarbage() {
        #expect(CertificatePin(pem: "no certificate here") == nil)
        #expect(CertificatePin(der: Data([0x30, 0x82, 0xFF, 0xFF, 0x00])) == nil)
        #expect(CertificatePin(der: Data()) == nil)
    }

    @Test func storeKeepsRunAndSavedPinsApart() throws {
        let url = tempURL("certificate_pins.json")
        let a = try #require(CertificatePin(pem: Self.v3))
        let b = try #require(CertificatePin(pem: Self.v1))
        let store = CertificatePinStore(url: url)
        store.trust(a, host: "FTP.example.com", port: 21, remember: true)
        store.trust(b, host: "ftp.example.com", port: 990, remember: false)
        #expect(store.pin(host: "ftp.example.com", port: 21) == a)
        #expect(store.pin(host: "ftp.example.com", port: 990) == b)

        let reloaded = CertificatePinStore(url: url)
        #expect(reloaded.pin(host: "ftp.example.com", port: 21) == a)
        #expect(reloaded.pin(host: "ftp.example.com", port: 990) == nil)  // "Connect Once" isn't saved

        // A run-only pin for a changed certificate takes precedence, without replacing the saved one.
        reloaded.trust(b, host: "ftp.example.com", port: 21, remember: false)
        #expect(reloaded.pin(host: "ftp.example.com", port: 21) == b)
        #expect(CertificatePinStore(url: url).pin(host: "ftp.example.com", port: 21) == a)

        reloaded.remove(host: "ftp.example.com", port: 21)
        #expect(CertificatePinStore(url: url).pin(host: "ftp.example.com", port: 21) == nil)
    }
}

@Suite struct ReleaseVerificationTests {
    private func release(tag: String = "v1.4.0", assets: String) -> Data {
        Data(#"{"tag_name":"\#(tag)","html_url":"https://github.com/o/r/releases/tag/\#(tag)","assets":[\#(assets)]}"#.utf8)
    }

    @Test func missingMacAssetAndTagWithoutV() throws {
        let info = try ReleaseCheck.parse(release(tag: "2.0.1", assets: #"{"name":"RemoteSSH-2.0.1-win-x64.exe","browser_download_url":"https://example.com/a.exe"}"#))
        #expect(info.version == "2.0.1")
        #expect(info.downloadURL == nil)
        #expect(info.sha256 == nil)
    }

    @Test func digestWithoutSHA256PrefixIsIgnored() throws {
        let info = try ReleaseCheck.parse(release(assets: #"{"name":"RemoteSSH-1.4.0-macos.zip","browser_download_url":"https://example.com/m.zip","digest":"md5:abc"}"#))
        #expect(info.downloadURL != nil)
        #expect(info.sha256 == nil)
    }

    @Test func verifyChecksum() throws {
        let file = tempURL("update.zip")
        try Data("RemoteSSH update".utf8).write(to: file)
        let digest = try ReleaseCheck.sha256(ofFileAt: file)
        #expect(digest.count == 64 && digest == digest.lowercased())

        try ReleaseCheck.verify(fileAt: file, sha256: digest)
        try ReleaseCheck.verify(fileAt: file, sha256: digest.uppercased())  // GitHub digests in any case
        let wrong = String(repeating: "0", count: 64)
        #expect(throws: ReleaseCheck.CheckError.checksumMismatch) { try ReleaseCheck.verify(fileAt: file, sha256: wrong) }
        #expect(throws: ReleaseCheck.CheckError.missingChecksum) { try ReleaseCheck.verify(fileAt: file, sha256: nil) }
        #expect(throws: ReleaseCheck.CheckError.missingChecksum) { try ReleaseCheck.verify(fileAt: file, sha256: "") }
    }

    @Test func parsedUppercaseDigestVerifies() throws {
        let file = tempURL("update.zip")
        try Data("payload".utf8).write(to: file)
        let digest = try ReleaseCheck.sha256(ofFileAt: file).uppercased()
        let info = try ReleaseCheck.parse(release(assets: #"{"name":"RemoteSSH-1.4.0-macos.zip","browser_download_url":"https://example.com/m.zip","digest":"sha256:\#(digest)"}"#))
        try ReleaseCheck.verify(fileAt: file, sha256: info.sha256)
    }
}

@Suite struct QueueStoreTests {
    @Test func savesOnlyChangesAndKeepsOrder() throws {
        let url = tempURL("queue.sqlite3")
        let store = QueueStore(url: url)
        var items = (0..<5).map { TransferItem(siteID: UUID(), direction: .upload, localPath: "/l/\($0)", remotePath: "/r/\($0)", size: Int64($0)) }
        #expect(store.save(items))
        items[1].status = .failed
        items[1].error = "boom"
        items[3].remotePath = "/r/renamed"
        items.remove(at: 2)
        items.append(TransferItem(siteID: UUID(), direction: .download, localPath: "/l/new", remotePath: "/r/new", size: nil))
        items[0].status = .finished
        #expect(store.save(items))

        let loaded = QueueStore(url: url).load()
        #expect(loaded.map(\.localPath) == ["/l/1", "/l/3", "/l/4", "/l/new"])
        #expect(loaded[0].status == .failed && loaded[0].error == "boom")
        #expect(loaded[1].remotePath == "/r/renamed")
        #expect(loaded[3].size == nil)
        #expect(loaded.map(\.id) == Array(items.dropFirst().map(\.id)))

        // A store that loaded the table appends after the existing rows.
        let again = QueueStore(url: url)
        var more = again.load()
        more.append(TransferItem(siteID: UUID(), direction: .upload, localPath: "/l/last", remotePath: "/r/last", size: 1))
        #expect(again.save(more))
        #expect(QueueStore(url: url).load().last?.localPath == "/l/last")
    }
}

@Suite struct TransferRetryTests {
    @Test func permanentFailures() {
        #expect(TransferRetry.isPermanent(RemoteSSHError.cancelled))
        #expect(TransferRetry.isPermanent(RemoteSSHError.authenticationFailed("no")))
        #expect(TransferRetry.isPermanent(RemoteSSHError.accessDenied("550 Permission denied")))
        #expect(TransferRetry.isPermanent(RemoteSSHError.fileNotFound("gone")))
        #expect(TransferRetry.isPermanent(RemoteSSHError.commandFailed("553 Permission denied.")))
        #expect(TransferRetry.isPermanent(CocoaError(.fileReadNoSuchFile)))
        #expect(TransferRetry.isPermanent(POSIXError(.EACCES)))
        #expect(!TransferRetry.isPermanent(RemoteSSHError.connectionFailed("timed out")))
        #expect(!TransferRetry.isPermanent(RemoteSSHError.commandFailed("421 Too many connections")))
        #expect(!TransferRetry.isPermanent(POSIXError(.ECONNRESET)))
    }

    @Test func backoff() {
        #expect((1...5).map { TransferRetry.delay(forAttempt: $0) } == [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(8)])
    }
}

@Suite struct DownloadTargetTests {
    @Test func failedOverwriteKeepsTheOldFile() async throws {
        let url = tempURL("file.txt")
        try Data("old contents".utf8).write(to: url)
        struct Boom: Error {}
        await #expect(throws: Boom.self) {
            try await DownloadTarget.write(to: url, resumeFrom: 0) { target in
                try target.handle.write(contentsOf: Data("partial".utf8))
                throw Boom()
            }
        }
        #expect(try Data(contentsOf: url) == Data("old contents".utf8))
        #expect(!FileManager.default.fileExists(atPath: DownloadTarget.partURL(for: url).path))
    }

    @Test func successReplacesAndResumeAppends() async throws {
        let url = tempURL("file.txt")
        try Data("old contents".utf8).write(to: url)
        try await DownloadTarget.write(to: url, resumeFrom: 0) { try $0.handle.write(contentsOf: Data("new".utf8)) }
        #expect(try Data(contentsOf: url) == Data("new".utf8))
        try await DownloadTarget.write(to: url, resumeFrom: 3) { try $0.handle.write(contentsOf: Data(" tail".utf8)) }
        #expect(try Data(contentsOf: url) == Data("new tail".utf8))
        #expect(!FileManager.default.fileExists(atPath: DownloadTarget.partURL(for: url).path))
    }
}
