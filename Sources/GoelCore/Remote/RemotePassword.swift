import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Portal password hashing/verification and random-secret minting. Never stored in the clear: kept as
/// `"v2$saltHex$hashHex"` PBKDF2-HMAC-SHA256; legacy `v1` (iterated SHA-256) verifies and re-hashes on set.
public enum RemotePassword {

    /// PBKDF2 iteration count: a verify costs tens of milliseconds — fine interactively, painful to
    /// brute force — while still not stalling the request loop.
    private static let iterations = 210_000
    private static let version = "v2"
    private static let legacyVersion = "v1"
    /// SHA-256 derived-key length (one PBKDF2 output block).
    private static let dkLen = 32

    /// Hash a password into `"v2$saltHex$hashHex"` with a fresh 16-byte random salt. Returns `""`
    /// for an empty password so callers treat "no password set" uniformly.
    public static func hash(_ password: String) -> String {
        guard !password.isEmpty else { return "" }
        let salt = randomBytes(16)
        let digest = pbkdf2(password: password, salt: salt)
        return "\(version)$\(salt.hexEncoded)$\(digest.hexEncoded)"
    }

    /// Constant-time check against a stored hash, handling current `v2` (PBKDF2) and legacy `v1`
    /// (iterated SHA-256). Any malformed or empty stored value fails closed.
    public static func verify(_ password: String, against stored: String) -> Bool {
        let parts = stored.split(separator: "$", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              let salt = Data(hexString: String(parts[1])), !salt.isEmpty else { return false }
        let expected = String(parts[2])
        let actual: String
        switch String(parts[0]) {
        case version:       actual = pbkdf2(password: password, salt: salt).hexEncoded
        case legacyVersion: actual = deriveLegacy(password: password, salt: salt).hexEncoded
        default:            return false
        }
        return RemoteRouter.constantTimeEquals(actual, expected)
    }

    /// PBKDF2-HMAC-SHA256, one 32-byte output block (RFC 2898). HMAC keyed by the password, not a bare
    /// hash chain, and built only from CryptoKit/swift-crypto primitives (no CommonCrypto dependency).
    private static func pbkdf2(password: String, salt: Data) -> Data {
        let key = SymmetricKey(data: Data(password.utf8))
        // U_1 = HMAC(password, salt || INT_32_BE(1))
        var message = salt
        message.append(contentsOf: [0, 0, 0, 1])
        var u = Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
        var result = u                       // T = U_1
        for _ in 1..<iterations {
            u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))  // U_j = HMAC(password, U_{j-1})
            for i in 0..<dkLen { result[i] ^= u[i] }                       // T ^= U_j
        }
        return result
    }

    /// Legacy `v1` KDF: iterate SHA-256 over `salt || password`, then over the
    /// running digest. Kept only so existing stored hashes still verify.
    private static func deriveLegacy(password: String, salt: Data) -> Data {
        var data = salt + Data(password.utf8)
        for _ in 0..<iterations {
            data = Data(SHA256.hash(data: data))
        }
        return data
    }

    /// Cryptographically-random lowercase-hex secret of `bytes` bytes, for session ids and the bearer
    /// token. `SystemRandomNumberGenerator` is CSPRNG-backed on Apple platforms.
    public static func randomHex(bytes: Int = 32) -> String {
        randomBytes(bytes).hexEncoded
    }

    private static func randomBytes(_ count: Int) -> Data {
        var rng = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: count)
        for i in 0..<count { bytes[i] = UInt8.random(in: UInt8.min...UInt8.max, using: &rng) }
        return Data(bytes)
    }
}

private extension Data {
    /// Lowercase hex, no separators.
    var hexEncoded: String {
        map { String(format: "%02x", $0) }.joined()
    }

    /// Parse an even-length lowercase/uppercase hex string, or `nil`.
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let byte = UInt8(String(chars[i...i+1]), radix: 16) else { return nil }
            bytes.append(byte)
            i += 2
        }
        self = Data(bytes)
    }
}
