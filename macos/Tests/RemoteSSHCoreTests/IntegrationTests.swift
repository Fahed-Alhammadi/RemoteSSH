import Foundation
import Testing
@testable import RemoteSSHCore

/// Live-server tests. Skipped unless the RSSH_* environment variables are set:
///   RSSH_FTP_HOST, RSSH_FTP_PORT, RSSH_FTP_USER, RSSH_FTP_PASS          (plain + explicit TLS)
///   RSSH_SFTP_HOST, RSSH_SFTP_PORT, RSSH_SFTP_USER, RSSH_SFTP_KEY        (ed25519 key file)
///   RSSH_SFTP_RSA_KEY, RSSH_SFTP_RSA_PASS                            (encrypted RSA key, optional)
private let env = ProcessInfo.processInfo.environment

final class AcceptAllPrompter: SessionPrompter, @unchecked Sendable {
    let lock = NSLock()
    var hostKeyPrompts = 0
    var certPrompts = 0
    let passphrase: String?

    init(passphrase: String? = nil) { self.passphrase = passphrase }

    func confirmHostKey(host: String, port: Int, keyType: String, fingerprint: String, changed: Bool) async -> Bool {
        lock.withLock { hostKeyPrompts += 1 }
        return true
    }
    func confirmCertificate(host: String, port: Int, reason: String) async -> Bool {
        lock.withLock { certPrompts += 1 }
        return true
    }
    func requestPassword(prompt: String) async -> String? { passphrase }
}

private func exercise(_ session: RemoteSession) async throws {
    try await session.connect()
    let home = try await session.homeDirectory()
    #expect(home.hasPrefix("/"))

    let dir = RemotePath.join(home, "fr-itest-\(UUID().uuidString.prefix(8))")
    try await session.makeDirectory(dir)

    // 1 MiB + odd tail so chunking/pipelining boundaries are crossed.
    let payload = Data((0..<(1_048_576 + 12_345)).map { _ in UInt8.random(in: 0...255) })
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("fr-up-\(UUID())")
    try payload.write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let remoteFile = RemotePath.join(dir, "file with spaces #1.bin")
    final class Last: @unchecked Sendable { let lock = NSLock(); var value: Int64 = 0 }
    let last = Last()
    try await session.upload(tmp, to: remoteFile, resumeFrom: 0, cancel: CancelToken()) { p in last.lock.withLock { last.value = p.transferred } }
    #expect(last.lock.withLock { last.value } == Int64(payload.count))

    let listing = try await session.list(dir)
    #expect(listing.map(\.name) == ["file with spaces #1.bin"])
    #expect(listing.first?.size == Int64(payload.count))
    #expect(try await session.fileSize(remoteFile) == Int64(payload.count))

    // Full download.
    let down = FileManager.default.temporaryDirectory.appendingPathComponent("fr-down-\(UUID())")
    defer { try? FileManager.default.removeItem(at: down) }
    try await session.download(remoteFile, to: down, resumeFrom: 0, cancel: CancelToken()) { _ in }
    #expect(try Data(contentsOf: down) == payload)

    // Resumed download: keep the first 300 000 bytes, fetch the rest.
    try payload.prefix(300_000).write(to: down)
    try await session.download(remoteFile, to: down, resumeFrom: 300_000, cancel: CancelToken()) { _ in }
    #expect(try Data(contentsOf: down) == payload)

    // Resumed upload.
    let partial = RemotePath.join(dir, "partial.bin")
    let head = FileManager.default.temporaryDirectory.appendingPathComponent("fr-head-\(UUID())")
    try payload.prefix(500_000).write(to: head)
    defer { try? FileManager.default.removeItem(at: head) }
    try await session.upload(head, to: partial, resumeFrom: 0, cancel: CancelToken()) { _ in }
    try await session.upload(tmp, to: partial, resumeFrom: 500_000, cancel: CancelToken()) { _ in }
    #expect(try await session.fileSize(partial) == Int64(payload.count))

    // Cancellation.
    let token = CancelToken()
    token.cancel()
    await #expect(throws: RemoteSSHError.self) {
        try await session.download(remoteFile, to: down, resumeFrom: 0, cancel: token) { _ in }
    }

    let renamed = RemotePath.join(dir, "renamed.bin")
    try await session.rename(remoteFile, to: renamed)
    try await session.chmod(renamed, mode: 0o600)
    let after = try await session.list(dir)
    #expect(Set(after.map(\.name)) == ["renamed.bin", "partial.bin"])
    // Some servers (pyftpdlib MLSD) only report RFC 3659 perm facts, not Unix bits.
    if let perms = after.first(where: { $0.name == "renamed.bin" })?.permissions, let bits = Permissions.bits(from: perms) {
        #expect(bits == 0o600)
    }

    try await session.deleteFile(renamed)
    try await session.deleteFile(partial)
    try await session.removeDirectory(dir)
    #expect(!(try await session.list(home)).contains { RemotePath.join(home, $0.name) == dir })
    await session.disconnect()
}

@Suite(.serialized) struct IntegrationTests {
    @Test(.enabled(if: env["RSSH_FTP_HOST"] != nil), arguments: [FTPEncryption.plain, .explicitIfAvailable, .requireExplicit])
    func ftp(_ encryption: FTPEncryption) async throws {
        let site = Site(host: env["RSSH_FTP_HOST"]!, port: Int(env["RSSH_FTP_PORT"] ?? "21")!, serverProtocol: .ftp,
                        encryption: encryption, logonType: .normal, user: env["RSSH_FTP_USER"]!)
        let prompter = AcceptAllPrompter()
        let session = SessionFactory.make(site: site, credentials: .init(password: env["RSSH_FTP_PASS"]!), options: .init(),
                                          prompter: prompter, hostKeys: KnownHostsStore(url: tmpURL()), log: { _ in })
        try await exercise(session)
        // Self-signed test certificate → exactly one trust prompt when TLS is used.
        #expect(prompter.certPrompts == (encryption == .plain ? 0 : 1))
    }

    @Test(.enabled(if: env["RSSH_FTP_HOST"] != nil))
    func ftpBadPassword() async throws {
        let site = Site(host: env["RSSH_FTP_HOST"]!, port: Int(env["RSSH_FTP_PORT"] ?? "21")!, serverProtocol: .ftp,
                        encryption: .plain, logonType: .normal, user: env["RSSH_FTP_USER"]!)
        let session = SessionFactory.make(site: site, credentials: .init(password: "wrong"), options: .init(),
                                          prompter: AcceptAllPrompter(), hostKeys: KnownHostsStore(url: tmpURL()), log: { _ in })
        await #expect(throws: RemoteSSHError.self) { try await session.connect() }
    }

    @Test(.enabled(if: env["RSSH_SFTP_HOST"] != nil))
    func sftpEd25519() async throws {
        let site = Site(host: env["RSSH_SFTP_HOST"]!, port: Int(env["RSSH_SFTP_PORT"] ?? "22")!, serverProtocol: .sftp,
                        logonType: .keyFile, user: env["RSSH_SFTP_USER"]!, keyFilePath: env["RSSH_SFTP_KEY"]!)
        let prompter = AcceptAllPrompter()
        let hosts = KnownHostsStore(url: tmpURL())
        let session = SessionFactory.make(site: site, credentials: .init(password: ""), options: .init(),
                                          prompter: prompter, hostKeys: hosts, log: { _ in })
        try await exercise(session)
        #expect(prompter.hostKeyPrompts == 1)

        // Second connection: key is now known → no prompt.
        let again = SessionFactory.make(site: site, credentials: .init(password: ""), options: .init(),
                                        prompter: prompter, hostKeys: hosts, log: { _ in })
        try await again.connect()
        await again.disconnect()
        #expect(prompter.hostKeyPrompts == 1)
    }

    @Test(.enabled(if: env["RSSH_SFTP_RSA_KEY"] != nil))
    func sftpEncryptedRSA() async throws {
        let site = Site(host: env["RSSH_SFTP_HOST"]!, port: Int(env["RSSH_SFTP_PORT"] ?? "22")!, serverProtocol: .sftp,
                        logonType: .keyFile, user: env["RSSH_SFTP_USER"]!, keyFilePath: env["RSSH_SFTP_RSA_KEY"]!)
        // Sessions hold the prompter weakly (it is the UI), so keep a strong reference here.
        let prompter = AcceptAllPrompter(passphrase: env["RSSH_SFTP_RSA_PASS"])
        let session = SessionFactory.make(site: site, credentials: .init(password: ""), options: .init(),
                                          prompter: prompter,
                                          hostKeys: KnownHostsStore(url: tmpURL()), log: { _ in })
        try await session.connect()
        #expect(try await session.homeDirectory().hasPrefix("/"))
        await session.disconnect()
    }

    @Test(.enabled(if: env["RSSH_SFTP_HOST"] != nil))
    func sftpRejectedHostKey() async throws {
        final class RejectAll: SessionPrompter, @unchecked Sendable {
            func confirmHostKey(host: String, port: Int, keyType: String, fingerprint: String, changed: Bool) async -> Bool { false }
            func confirmCertificate(host: String, port: Int, reason: String) async -> Bool { false }
            func requestPassword(prompt: String) async -> String? { nil }
        }
        let site = Site(host: env["RSSH_SFTP_HOST"]!, port: Int(env["RSSH_SFTP_PORT"] ?? "22")!, serverProtocol: .sftp,
                        logonType: .keyFile, user: env["RSSH_SFTP_USER"]!, keyFilePath: env["RSSH_SFTP_KEY"]!)
        let prompter = RejectAll()
        let session = SessionFactory.make(site: site, credentials: .init(password: ""), options: .init(),
                                          prompter: prompter, hostKeys: KnownHostsStore(url: tmpURL()), log: { _ in })
        await #expect(throws: RemoteSSHError.self) { try await session.connect() }
    }
}

private func tmpURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("fr-known-\(UUID()).json")
}
