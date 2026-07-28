import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Never stored in the clear: `"v2$saltHex$hashHex"` PBKDF2-HMAC-SHA256; legacy `v1` still verifies and is re-hashed on set.
public enum RemotePassword {

    /// PBKDF2 iterations: a verify costs tens of milliseconds — fine interactively, painful to brute force.
    private static let iterations = 210_000
    private static let version = "v2"
    private static let legacyVersion = "v1"
    private static let dkLen = 32

    /// Returns "" for an empty password so callers treat "no password set" uniformly.
    public static func hash(_ password: String) -> String {
        guard !password.isEmpty else { return "" }
        let salt = randomBytes(16)
        let digest = pbkdf2(password: password, salt: salt)
        return "\(version)$\(salt.hexEncoded)$\(digest.hexEncoded)"
    }

    /// Constant-time comparison; any malformed or empty stored value fails closed.
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

    /// PBKDF2-HMAC-SHA256, one 32-byte block (RFC 2898): HMAC keyed by the password, not a bare hash chain.
    private static func pbkdf2(password: String, salt: Data) -> Data {
        let key = SymmetricKey(data: Data(password.utf8))
        // U_1 = HMAC(password, salt || INT_32_BE(1))
        var message = salt
        message.append(contentsOf: [0, 0, 0, 1])
        var u = Data(HMAC<SHA256>.authenticationCode(for: message, using: key))
        var result = u
        for _ in 1..<iterations {
            u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
            for i in 0..<dkLen { result[i] ^= u[i] }
        }
        return result
    }

    /// Legacy `v1` KDF, kept only so existing stored hashes still verify.
    private static func deriveLegacy(password: String, salt: Data) -> Data {
        var data = salt + Data(password.utf8)
        for _ in 0..<iterations {
            data = Data(SHA256.hash(data: data))
        }
        return data
    }

    /// `SystemRandomNumberGenerator` is CSPRNG-backed — used for session ids and the bearer token.
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
    var hexEncoded: String {
        map { String(format: "%02x", $0) }.joined()
    }

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
