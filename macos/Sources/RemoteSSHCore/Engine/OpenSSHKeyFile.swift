import Foundation

/// Minimal reader for the "openssh-key-v1" private key container — just enough to tell whether
/// a key is encrypted and to canonicalise padding for Citadel.
///
/// Some generators pad the unencrypted private section to 16 bytes. OpenSSH accepts that, but
/// Citadel 0.12.0 rejects any padding >= 8 for cipher "none" (`invalidPadding`).
struct OpenSSHKeyFile {
    let cipherName: String
    private let blob: [UInt8]
    private let privateSectionRange: Range<Int>

    var isEncrypted: Bool { cipherName != "none" }

    private static let magic = Array("openssh-key-v1\0".utf8)
    private static let begin = "-----BEGIN OPENSSH PRIVATE KEY-----"
    private static let end = "-----END OPENSSH PRIVATE KEY-----"

    init?(_ text: String) {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let b = lines.firstIndex(of: Self.begin), let e = lines.firstIndex(of: Self.end), b < e,
              let data = Data(base64Encoded: lines[(b + 1)..<e].joined()) else { return nil }
        let blob = [UInt8](data)
        guard blob.starts(with: Self.magic) else { return nil }
        var r = Reader(bytes: blob, offset: Self.magic.count)
        guard let cipher = r.string(), r.string() != nil /* kdf */, r.string() != nil /* kdf options */,
              let count = r.uint32(), count == 1, r.string() != nil /* public key */,
              let sectionLength = r.uint32() else { return nil }
        let start = r.offset
        guard start + Int(sectionLength) <= blob.count else { return nil }
        self.cipherName = String(decoding: cipher, as: UTF8.self)
        self.blob = blob
        self.privateSectionRange = start..<(start + Int(sectionLength))
    }

    /// Returns the key re-encoded with canonical padding (block size 8), or nil when it is
    /// encrypted, already canonical, or of an unknown key type.
    func canonicalPaddingText() -> String? {
        guard !isEncrypted else { return nil }
        let section = Array(blob[privateSectionRange])
        guard let contentLength = Self.contentLength(of: section) else { return nil }
        let padding = section.count - contentLength
        guard padding >= 8 else { return nil }

        var newSection = Array(section[..<contentLength])
        var pad: UInt8 = 1
        while newSection.count % 8 != 0 { newSection.append(pad); pad += 1 }

        var out = Array(blob[..<(privateSectionRange.lowerBound - 4)])
        let len = UInt32(newSection.count)
        out += [UInt8(len >> 24), UInt8(len >> 16 & 0xff), UInt8(len >> 8 & 0xff), UInt8(len & 0xff)]
        out += newSection
        out += blob[privateSectionRange.upperBound...]

        let b64 = Data(out).base64EncodedString()
        var body = ""
        var idx = b64.startIndex
        while idx < b64.endIndex {
            let next = b64.index(idx, offsetBy: 70, limitedBy: b64.endIndex) ?? b64.endIndex
            body += b64[idx..<next] + "\n"
            idx = next
        }
        return Self.begin + "\n" + body + Self.end + "\n"
    }

    /// Length of checkints + key fields + comment inside an unencrypted private section.
    private static func contentLength(of section: [UInt8]) -> Int? {
        var r = Reader(bytes: section, offset: 0)
        guard let c1 = r.uint32(), let c2 = r.uint32(), c1 == c2, let typeBytes = r.string() else { return nil }
        let fields: Int
        switch String(decoding: typeBytes, as: UTF8.self) {
        case "ssh-ed25519": fields = 2                                    // pub, priv
        case "ssh-rsa": fields = 6                                        // n, e, d, iqmp, p, q
        case let t where t.hasPrefix("ecdsa-sha2-"): fields = 3          // curve, pub, priv
        default: return nil
        }
        for _ in 0..<fields { guard r.string() != nil else { return nil } }
        guard r.string() != nil /* comment */ else { return nil }
        return r.offset
    }

    private struct Reader {
        let bytes: [UInt8]
        var offset: Int

        mutating func uint32() -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            defer { offset += 4 }
            return bytes[offset..<offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }

        mutating func string() -> ArraySlice<UInt8>? {
            guard let n = uint32(), offset + Int(n) <= bytes.count else { return nil }
            defer { offset += Int(n) }
            return bytes[offset..<offset + Int(n)]
        }
    }
}
