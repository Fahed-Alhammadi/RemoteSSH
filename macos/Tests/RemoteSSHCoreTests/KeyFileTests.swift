import Citadel
import CryptoKit
import Foundation
import Testing
@testable import RemoteSSHCore

@Suite struct KeyFileTests {
    /// Unencrypted ed25519 key (fresh random key per run, so no private key is committed) whose
    /// private section is padded to 16 bytes (13 padding bytes) instead of the canonical 8.
    /// OpenSSH accepts it; Citadel 0.12.0 alone throws invalidPadding.
    static let key = Curve25519.Signing.PrivateKey()
    static let padded16: String = {
        func string(_ d: Data) -> Data { var n = UInt32(d.count).bigEndian; return Data(bytes: &n, count: 4) + d }
        func string(_ s: String) -> Data { string(Data(s.utf8)) }
        let pub = key.publicKey.rawRepresentation
        let pubBlob = string("ssh-ed25519") + string(pub)
        var priv = Data([0xA1, 0xB2, 0xC3, 0xD4, 0xA1, 0xB2, 0xC3, 0xD4]) // matching check ints
        priv += pubBlob + string(key.rawRepresentation + pub) + string("")
        var pad: UInt8 = 1
        while priv.count % 16 != 0 { priv.append(pad); pad += 1 }
        var blob = Data("openssh-key-v1".utf8) + Data([0])
        blob += string("none") + string("none") + string(Data()) + Data([0, 0, 0, 1])
        blob += string(pubBlob) + string(priv)
        let body = blob.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(body)\n-----END OPENSSH PRIVATE KEY-----"
    }()

    @Test func citadelRejectsSixteenBytePadding() {
        #expect(throws: (any Error).self) { try Curve25519.Signing.PrivateKey(sshEd25519: Self.padded16) }
    }

    @Test func canonicalPaddingMakesKeyParse() throws {
        let file = try #require(OpenSSHKeyFile(Self.padded16))
        #expect(!file.isEncrypted)
        let fixed = try #require(file.canonicalPaddingText())
        let key = try Curve25519.Signing.PrivateKey(sshEd25519: fixed)
        // Same key material as the generated key.
        #expect(key.publicKey.rawRepresentation == Self.key.publicKey.rawRepresentation)
        // Already canonical → nothing to rewrite.
        #expect(OpenSSHKeyFile(fixed)?.canonicalPaddingText() == nil)
    }

    @Test func rejectsNonOpenSSHText() {
        #expect(OpenSSHKeyFile("-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----") == nil)
    }
}
