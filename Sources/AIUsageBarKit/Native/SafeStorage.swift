import CommonCrypto
import Foundation

/// Chromium/Electron `safeStorage` (os_crypt) decryption, ported from
/// upstream `src/safe_storage.rs`. Claude Desktop stores its OAuth token
/// cache encrypted with a key derived from the login-Keychain item
/// `Claude Safe Storage` — PBKDF2-HMAC-SHA1("saltysalt", 1003 rounds) →
/// AES-128-CBC with a fixed 16-space IV and a `v10` prefix on the blob.
public enum SafeStorage {
    public static let keychainService = "Claude Safe Storage"
    static let salt = Data("saltysalt".utf8)
    static let rounds: UInt32 = 1003
    static let keyLength = 16
    static let iv = Data(repeating: 0x20, count: 16)
    static let prefix = Data("v10".utf8)

    public static func deriveKey(secret: Data) -> Data {
        var key = Data(count: keyLength)
        key.withUnsafeMutableBytes { keyPtr in
            secret.withUnsafeBytes { secretPtr in
                salt.withUnsafeBytes { saltPtr in
                    _ = CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        secretPtr.baseAddress?.assumingMemoryBound(to: Int8.self),
                        secret.count,
                        saltPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        rounds,
                        keyPtr.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyLength
                    )
                }
            }
        }
        return key
    }

    /// The AES key for this machine's Claude Desktop, from the login Keychain.
    /// Nil when the item doesn't exist (no Claude Desktop installed).
    public static func macKey() -> Data? {
        guard let secret = Keychain.readPassword(service: keychainService) else { return nil }
        return deriveKey(secret: Data(secret.utf8))
    }

    /// Decrypt a base64 `v10…` blob. Nil on bad base64, missing prefix, or a
    /// padding failure (wrong key) — never garbage. The PKCS7 padding is
    /// validated by hand: CommonCrypto's one-shot decrypt does not reliably
    /// reject invalid padding.
    public static func decrypt(key: Data, valueB64: String) -> Data? {
        guard key.count == keyLength,
              let raw = Data(base64Encoded: valueB64.trimmingCharacters(in: .whitespacesAndNewlines)),
              raw.count > prefix.count, raw.prefix(prefix.count) == prefix
        else { return nil }
        let ciphertext = Data(raw.dropFirst(prefix.count))
        guard !ciphertext.isEmpty, ciphertext.count % kCCBlockSizeAES128 == 0 else { return nil }

        var out = Data(count: ciphertext.count)
        var outLen = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            key.withUnsafeBytes { keyPtr in
                iv.withUnsafeBytes { ivPtr in
                    ciphertext.withUnsafeBytes { ctPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0),
                            keyPtr.baseAddress, keyLength,
                            ivPtr.baseAddress,
                            ctPtr.baseAddress, ciphertext.count,
                            outPtr.baseAddress, outPtr.count,
                            &outLen
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess, outLen == ciphertext.count else { return nil }
        let plain = out.prefix(outLen)

        // Strict PKCS7 strip: the pad byte n must be 1...16 and the last n
        // bytes must all equal n.
        guard let padByte = plain.last else { return nil }
        let pad = Int(padByte)
        guard (1...kCCBlockSizeAES128).contains(pad), plain.count >= pad,
              plain.suffix(pad).allSatisfy({ $0 == padByte })
        else { return nil }
        return plain.prefix(plain.count - pad)
    }
}
