import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Password hashing + verification and random-secret minting for the web portal.
///
/// The portal login password is never stored in the clear. It is kept as a
/// versioned, salted, iterated SHA-256 digest — `"v1$saltHex$hashHex"` — so a
/// leaked settings file doesn't hand out the password, and the version prefix
/// reserves a clean upgrade path to a stronger KDF later. This is deliberately
/// simple (CryptoKit's `SHA256`, already linked by `ChecksumVerifier`) rather
/// than PBKDF2/Argon2: it protects a **rate-limited LAN control panel**, not a
/// public credential database, and the iteration count still makes offline
/// guessing costly.
public enum RemotePassword {

    /// Iteration count for the derive loop. High enough that a single verify is
    /// tens of milliseconds (fine for an interactive login, painful to brute
    /// force), low enough not to stall the request loop.
    private static let iterations = 210_000
    private static let version = "v1"

    /// Hash a plaintext password into a storable `"v1$saltHex$hashHex"` string
    /// with a fresh 16-byte random salt. Returns `""` for an empty password so
    /// callers can treat "no password set" uniformly.
    public static func hash(_ password: String) -> String {
        guard !password.isEmpty else { return "" }
        let salt = randomBytes(16)
        let digest = derive(password: password, salt: salt)
        return "\(version)$\(salt.hexEncoded)$\(digest.hexEncoded)"
    }

    /// Constant-time check of a plaintext password against a stored hash string.
    /// Any malformed/empty stored value fails closed.
    public static func verify(_ password: String, against stored: String) -> Bool {
        let parts = stored.split(separator: "$", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == version,
              let salt = Data(hexString: String(parts[1])), !salt.isEmpty else { return false }
        let expected = String(parts[2])
        let actual = derive(password: password, salt: salt).hexEncoded
        return RemoteRouter.constantTimeEquals(actual, expected)
    }

    /// Iterate SHA-256 over `salt || password`, then repeatedly over the running
    /// digest. The salt defeats precomputation; the iterations add work per guess.
    private static func derive(password: String, salt: Data) -> Data {
        var data = salt + Data(password.utf8)
        for _ in 0..<iterations {
            data = Data(SHA256.hash(data: data))
        }
        return data
    }

    /// A cryptographically-random lowercase-hex secret of `bytes` bytes — used for
    /// session identifiers and the bearer token. `SystemRandomNumberGenerator` is
    /// CSPRNG-backed on Apple platforms.
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
