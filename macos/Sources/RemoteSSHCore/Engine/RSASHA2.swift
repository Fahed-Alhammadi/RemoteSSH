import Citadel
import CRSAShim
import CryptoKit
import Foundation
import NIOCore
import NIOSSH

// RSA public-key authentication with rsa-sha2-512 / rsa-sha2-256 (RFC 8332).
//
// Citadel 0.12.0 only signs RSA keys with SHA-1 ("ssh-rsa"), which OpenSSH ≥ 8.8 rejects by
// default. We reuse Citadel's OpenSSH key parser (it handles bcrypt + AES decryption), read
// the key material, and sign with BoringSSL using SHA-2. Citadel is pinned to an exact version
// because this reads one of its internal properties; IntegrationTests.sftpEncryptedRSA guards it.

protocol RSASHA2Variant {
    static var name: String { get }
    static var nid: Int32 { get }
    static func digest<D: DataProtocol>(_ data: D) -> [UInt8]
}

enum RSASHA512: RSASHA2Variant {
    static let name = "rsa-sha2-512"
    static let nid = Int32(CRSA_NID_sha512)
    static func digest<D: DataProtocol>(_ data: D) -> [UInt8] { Array(SHA512.hash(data: data)) }
}

enum RSASHA256: RSASHA2Variant {
    static let name = "rsa-sha2-256"
    static let nid = Int32(CRSA_NID_sha256)
    static func digest<D: DataProtocol>(_ data: D) -> [UInt8] { Array(SHA256.hash(data: data)) }
}

struct RSAKeyMaterial {
    let e: [UInt8]
    let n: [UInt8]
    /// BoringSSL BIGNUM* owned by the Citadel key (kept alive via `owner`).
    let d: UnsafeMutableRawPointer
    let owner: Insecure.RSA.PrivateKey

    init(_ key: Insecure.RSA.PrivateKey) throws {
        guard let pub = key.publicKey as? Insecure.RSA.PublicKey else { throw RemoteSSHError.unsupported("Unexpected RSA key type") }
        var buf = ByteBuffer(data: pub.rawRepresentation)
        guard let eLen = buf.readInteger(as: UInt32.self), let e = buf.readBytes(length: Int(eLen)),
              let nLen = buf.readInteger(as: UInt32.self), let n = buf.readBytes(length: Int(nLen)) else {
            throw RemoteSSHError.unsupported("Malformed RSA public key")
        }
        guard let child = Mirror(reflecting: key).children.first(where: { $0.label == "privateExponent" }),
              let d = Self.rawPointer(child.value) else {
            throw RemoteSSHError.unsupported("RSA SHA-2 signing unavailable with this Citadel version")
        }
        self.e = e
        self.n = n
        self.d = d
        self.owner = key
    }

    private static func rawPointer(_ value: Any) -> UnsafeMutableRawPointer? {
        func open<T>(_ v: T) -> UnsafeMutableRawPointer? {
            guard MemoryLayout<T>.size == MemoryLayout<UnsafeMutableRawPointer>.size,
                  String(describing: T.self).hasPrefix("UnsafeMutablePointer") else { return nil }
            return unsafeBitCast(v, to: UnsafeMutableRawPointer.self)
        }
        return _openExistential(value, do: open)
    }

    /// "ssh-rsa" public key blob body: mpint e, mpint n.
    var publicBlobBody: [UInt8] {
        var b = ByteBuffer()
        b.writeInteger(UInt32(e.count)); b.writeBytes(e)
        b.writeInteger(UInt32(n.count)); b.writeBytes(n)
        return b.readBytes(length: b.readableBytes) ?? []
    }

    func withRSA<T>(includePrivate: Bool, _ body: (UnsafeMutableRawPointer) throws -> T) throws -> T {
        guard let rsa = CCryptoBoringSSL_RSA_new() else { throw RemoteSSHError.unsupported("RSA_new failed") }
        defer { CCryptoBoringSSL_RSA_free(rsa) }
        let nBN = n.withUnsafeBufferPointer { CCryptoBoringSSL_BN_bin2bn($0.baseAddress, $0.count, nil) }
        let eBN = e.withUnsafeBufferPointer { CCryptoBoringSSL_BN_bin2bn($0.baseAddress, $0.count, nil) }
        let dBN = includePrivate ? CCryptoBoringSSL_BN_dup(d) : nil
        guard CCryptoBoringSSL_RSA_set0_key(rsa, nBN, eBN, dBN) == 1 else { throw RemoteSSHError.unsupported("RSA_set0_key failed") }
        return try body(rsa)
    }
}

final class RSASHA2Signature<V: RSASHA2Variant>: NIOSSHSignatureProtocol {
    static var signaturePrefix: String { V.name }
    let rawRepresentation: Data

    init(_ raw: Data) { rawRepresentation = raw }

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeInteger(UInt32(rawRepresentation.count)) + buffer.writeBytes(rawRepresentation)
    }

    static func read(from buffer: inout ByteBuffer) throws -> Self {
        guard let len = buffer.readInteger(as: UInt32.self), let bytes = buffer.readData(length: Int(len)) else {
            throw RemoteSSHError.unsupported("Malformed RSA signature")
        }
        return Self(bytes)
    }
}

final class RSASHA2PublicKey<V: RSASHA2Variant>: NIOSSHPublicKeyProtocol {
    static var publicKeyPrefix: String { V.name }
    let material: RSAKeyMaterial

    init(_ material: RSAKeyMaterial) { self.material = material }

    var rawRepresentation: Data { Data(material.publicBlobBody) }

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        let digest = V.digest(data)
        let sig = [UInt8](signature.rawRepresentation)
        return (try? material.withRSA(includePrivate: false) { rsa in
            CCryptoBoringSSL_RSA_verify(V.nid, digest, digest.count, sig, sig.count, rsa) == 1
        }) ?? false
    }

    /// NIOSSH writes the algorithm name (rsa-sha2-*) as the key-blob type, but RFC 8332 requires
    /// the blob to stay "ssh-rsa". Replace the header NIOSSH just wrote and return the net size.
    func write(to buffer: inout ByteBuffer) -> Int {
        let prefix = Array(V.name.utf8)
        var header = ByteBuffer()
        header.writeInteger(UInt32(prefix.count))
        header.writeBytes(prefix)
        let headerBytes = header.readableBytesView
        var removed = 0
        if buffer.writerIndex - buffer.readerIndex >= headerBytes.count,
           let previous = buffer.getBytes(at: buffer.writerIndex - headerBytes.count, length: headerBytes.count),
           previous.elementsEqual(headerBytes) {
            buffer.moveWriterIndex(to: buffer.writerIndex - headerBytes.count)
            removed = headerBytes.count
        }
        var written = 0
        if removed > 0 {
            let type = Array("ssh-rsa".utf8)
            written += buffer.writeInteger(UInt32(type.count))
            written += buffer.writeBytes(type)
        }
        written += buffer.writeBytes(material.publicBlobBody)
        return written - removed
    }

    static func read(from buffer: inout ByteBuffer) throws -> Self {
        throw RemoteSSHError.unsupported("Parsing \(V.name) keys is not supported")
    }
}

final class RSASHA2PrivateKey<V: RSASHA2Variant>: NIOSSHPrivateKeyProtocol {
    static var keyPrefix: String { V.name }
    let material: RSAKeyMaterial
    let publicKey: NIOSSHPublicKeyProtocol

    init(_ material: RSAKeyMaterial) {
        self.material = material
        self.publicKey = RSASHA2PublicKey<V>(material)
    }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        let digest = V.digest(data)
        var out = [UInt8](repeating: 0, count: 2048)
        var outLen: UInt32 = 0
        let ok = try material.withRSA(includePrivate: true) { rsa in
            CCryptoBoringSSL_RSA_sign(V.nid, digest, digest.count, &out, &outLen, rsa)
        }
        guard ok == 1 else { throw RemoteSSHError.authenticationFailed("RSA signing failed") }
        return RSASHA2Signature<V>(Data(out.prefix(Int(outLen))))
    }
}

/// Offers rsa-sha2-512, then rsa-sha2-256, then legacy ssh-rsa — the same order as OpenSSH.
final class RSAAuthDelegate: NIOSSHClientUserAuthenticationDelegate {
    private var offers: [NIOSSHPrivateKey]
    private let username: String

    init(username: String, key: Insecure.RSA.PrivateKey) {
        self.username = username
        var offers: [NIOSSHPrivateKey] = []
        if let material = try? RSAKeyMaterial(key) {
            offers.append(NIOSSHPrivateKey(custom: RSASHA2PrivateKey<RSASHA512>(material)))
            offers.append(NIOSSHPrivateKey(custom: RSASHA2PrivateKey<RSASHA256>(material)))
        }
        offers.append(NIOSSHPrivateKey(custom: key))
        self.offers = offers
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard availableMethods.contains(.publicKey), !offers.isEmpty else {
            nextChallengePromise.fail(RemoteSSHError.authenticationFailed("Server rejected the RSA key"))
            return
        }
        let key = offers.removeFirst()
        nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .privateKey(.init(privateKey: key))))
    }
}
