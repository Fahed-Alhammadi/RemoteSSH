import Foundation
import Testing
@testable import RemoteSSHCore

@Suite struct ListingParserTests {
    @Test func testMLSD() {
        let text = """
        type=cdir;modify=20240101000000;UNIX.mode=0755; .
        type=file;size=1234;modify=20240315083000;UNIX.mode=0644;UNIX.owner=web; index.html
        type=dir;modify=20240101120000;UNIX.mode=0755; my folder
        """
        let e = ListingParser.parse(text)
        #expect(e.count == 2)
        #expect(e[0].name == "index.html")
        #expect(e[0].size == 1234)
        #expect(e[0].permissions == "-rw-r--r--")
        #expect(e[0].owner == "web")
        #expect(e[1].isDirectory)
        #expect(e[1].name == "my folder")
    }

    @Test func testUnix() {
        let text = """
        total 12
        drwxr-xr-x    2 user     group        4096 Jan 15 10:30 public html
        -rw-r--r--    1 user     group       52310 Mar  2  2021 report 2021.pdf
        lrwxrwxrwx    1 root     root           11 Feb  1 09:00 link -> /var/www
        """
        let e = ListingParser.parse(text)
        #expect(e.map(\.name) == ["public html", "report 2021.pdf", "link"])
        #expect(e[0].isDirectory)
        #expect(e[1].size == 52310)
        #expect(Calendar(identifier: .gregorian).component(.year, from: e[1].modified!) == 2021)
        #expect(e[2].isLink)
        #expect(e[2].linkTarget == "/var/www")
        #expect(e[0].owner == "user")
        #expect(e[0].group == "group")
    }

    @Test func testDOS() {
        let text = """
        01-15-24  10:30AM       <DIR>          wwwroot
        03-02-21  02:05PM                52310 report.pdf
        """
        let e = ListingParser.parse(text)
        #expect(e.count == 2)
        #expect(e[0].isDirectory)
        #expect(e[1].size == 52310)
        #expect(e[1].modified != nil)
    }
}

@Suite struct ModelTests {
    @Test func testQuickConnectURL() throws {
        let q = try QuickConnectInput.parse(host: "sftp://bob:p%40ss@example.com:2222/var/www", user: "", password: "", port: "")
        #expect(q.site.serverProtocol == .sftp)
        #expect(q.site.host == "example.com")
        #expect(q.site.port == 2222)
        #expect(q.site.user == "bob")
        #expect(q.password == "p@ss")
        #expect(q.initialPath == "/var/www")
    }

    @Test func testQuickConnectPlainHost() throws {
        let q = try QuickConnectInput.parse(host: "ftp.example.com", user: "", password: "", port: "")
        #expect(q.site.serverProtocol == .ftp)
        #expect(q.site.logonType == .anonymous)
        #expect(q.site.effectivePort == 21)
        let s = try QuickConnectInput.parse(host: "host", user: "u", password: "p", port: "22")
        #expect(s.site.serverProtocol == .sftp)
    }

    @Test func testImplicitPort() {
        let s = Site(host: "h", serverProtocol: .ftp, encryption: .requireImplicit)
        #expect(s.effectivePort == 990)
    }

    @Test func testPermissions() {
        #expect(Permissions.symbolic(mode: 0o040755) == "drwxr-xr-x")
        #expect(Permissions.bits(from: "-rw-r--r--") == 0o644)
        #expect(Permissions.bits(from: "755") == 0o755)
        #expect(Permissions.octalString(0o640) == "640")
    }

    @Test func testRemotePath() {
        #expect(RemotePath.join("/a", "b") == "/a/b")
        #expect(RemotePath.join("/", "b") == "/b")
        #expect(RemotePath.parent(of: "/a/b/") == "/a")
        #expect(RemotePath.parent(of: "/a") == "/")
        #expect(RemotePath.normalize("/a/./b/../c") == "/a/c")
    }

    @Test func testSiteArchiveRoundTrip() throws {
        let a = Site(name: "Prod", folder: "Work", host: "sftp.example.com", serverProtocol: .sftp, user: "alice")
        let b = Site(name: "Public", host: "ftp.example.org", serverProtocol: .ftp, encryption: .requireExplicit, logonType: .anonymous)
        let data = try SiteArchive(sites: [a, b], passwords: [a.id: "secret"]).encoded()

        let imported = try SiteArchive.decode(data).importable()
        #expect(imported.sites.map(\.name) == ["Prod", "Public"])
        #expect(imported.sites[0].folder == "Work")
        #expect(imported.sites[1].encryption == .requireExplicit)
        // Fresh ids so a second import never collides; passwords follow their site.
        #expect(imported.sites[0].id != a.id)
        #expect(imported.passwords[imported.sites[0].id] == "secret")
        #expect(imported.passwords.count == 1)
        // Passwords are a JSON object keyed by the site's UUID string (shared with the desktop app).
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect((json?["passwords"] as? [String: String])?[a.id.uuidString] == "secret")
    }

    @Test func testSiteArchiveWithoutPasswords() throws {
        let data = try SiteArchive(sites: [Site(host: "h")]).encoded()
        #expect(!String(decoding: data, as: UTF8.self).contains("passwords"))
        #expect(try SiteArchive.decode(data).importable().passwords.isEmpty)
    }

    @Test func testSiteArchiveRejectsForeignFiles() {
        #expect(throws: RemoteSSHError.self) { try SiteArchive.decode(Data("[]".utf8)) }
        #expect(throws: RemoteSSHError.self) { try SiteArchive.decode(Data(#"{"format":"other","version":1,"exportedAt":"2026-01-01T00:00:00Z","sites":[]}"#.utf8)) }
    }

    @Test func testFingerprint() {
        // ssh-keygen -lf of this ed25519 public key prints SHA256:... (43 chars, no padding)
        let fp = KnownHostsStore.fingerprint(ofOpenSSHKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl")
        #expect(fp.hasPrefix("SHA256:"))
        #expect(fp.count == 7 + 43)
    }

    @Test func testQueueStoreRoundTrip() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("q-\(UUID()).sqlite3")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = QueueStore(url: url)
        var a = TransferItem(siteID: UUID(), direction: .upload, localPath: "/tmp/a", remotePath: "/a", size: 10)
        a.status = .transferring
        var done = TransferItem(siteID: UUID(), direction: .download, localPath: "/tmp/b", remotePath: "/b", size: nil)
        done.status = .finished
        store.save([a, done])
        let loaded = QueueStore(url: url).load()
        #expect(loaded.count == 1)
        #expect(loaded[0].status == .queued)
        #expect(loaded[0].size == 10)
    }
}

@Suite struct ReleaseCheckTests {
    @Test func testCompare() {
        #expect(ReleaseCheck.compare("v1.2.10", "1.2.9") == .orderedDescending)
        #expect(ReleaseCheck.compare("1.0.0", "v1.0.0") == .orderedSame)
        #expect(ReleaseCheck.compare("1.0", "1.0.1") == .orderedAscending)
    }

    @Test func testParse() throws {
        let json = """
        [{"tag_name":"windows-v2.0.0","html_url":"https://github.com/o/r/releases/tag/windows-v2.0.0","draft":false,"prerelease":false,"assets":[
           {"name":"RemoteSSH-2.0.0-win-x64.exe","browser_download_url":"https://example.com/a.exe"}]},
         {"tag_name":"macos-v1.5.0","html_url":"https://github.com/o/r/releases/tag/macos-v1.5.0","draft":true,"prerelease":false,"assets":[]},
         {"tag_name":"macos-v1.4.10","html_url":"https://github.com/o/r/releases/tag/macos-v1.4.10","draft":false,"prerelease":false,"assets":[
           {"name":"RemoteSSH-1.4.10-macos.zip","browser_download_url":"https://example.com/m.zip","digest":"sha256:ABCDEF"}]},
         {"tag_name":"macos-v1.4.9","html_url":"https://github.com/o/r/releases/tag/macos-v1.4.9","draft":false,"prerelease":false,"assets":[]}]
        """
        let info = try #require(try ReleaseCheck.parse(Data(json.utf8)))
        #expect(info.version == "1.4.10")
        #expect(info.downloadURL?.lastPathComponent == "m.zip")
        #expect(info.sha256 == "abcdef")
        #expect(try ReleaseCheck.parse(Data("[]".utf8)) == nil)
    }
}
