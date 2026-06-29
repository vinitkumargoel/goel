import Foundation
import CryptoKit

/// A file-integrity hash algorithm the verifier understands.
public enum ChecksumAlgorithm: String, Codable, Sendable, CaseIterable, Hashable {
    case md5
    case sha1
    case sha256

    public var displayName: String {
        switch self {
        case .md5: return "MD5"
        case .sha1: return "SHA-1"
        case .sha256: return "SHA-256"
        }
    }

    /// The number of hex characters a digest of this algorithm produces, used to
    /// auto-detect the algorithm from a pasted hash.
    public var hexLength: Int {
        switch self {
        case .md5: return 32
        case .sha1: return 40
        case .sha256: return 64
        }
    }
}

/// An expected file checksum: an algorithm plus the lowercase hex digest a
/// finished download must match before it is marked complete.
public struct Checksum: Codable, Sendable, Hashable {
    public var algorithm: ChecksumAlgorithm
    /// Normalized lowercase hex digest.
    public var value: String

    public init(algorithm: ChecksumAlgorithm, value: String) {
        self.algorithm = algorithm
        self.value = Checksum.normalize(value)
    }

    /// Lowercased, whitespace-trimmed hex.
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Parse a user-entered hash. When `algorithm` is omitted it is inferred from
    /// the hex length (32 → MD5, 40 → SHA-1, 64 → SHA-256). Returns `nil` if the
    /// string is not valid hex of a recognised length.
    public static func parse(_ raw: String, algorithm: ChecksumAlgorithm? = nil) -> Checksum? {
        let hex = normalize(raw)
        guard !hex.isEmpty, hex.allSatisfy(\.isHexDigit) else { return nil }
        if let algo = algorithm {
            guard hex.count == algo.hexLength else { return nil }
            return Checksum(algorithm: algo, value: hex)
        }
        guard let inferred = ChecksumAlgorithm.allCases.first(where: { $0.hexLength == hex.count }) else {
            return nil
        }
        return Checksum(algorithm: inferred, value: hex)
    }
}

/// Streams a file through a hash function and compares it to an expected digest.
///
/// Reads in fixed windows so multi-gigabyte files never load fully into memory,
/// and checks for cancellation between chunks so a removed/paused task stops
/// hashing promptly.
public enum ChecksumVerifier {
    /// Read window: 1 MiB.
    static let chunkSize = 1 << 20

    /// Compute the lowercase hex digest of the file at `url` using `algorithm`.
    public static func digest(fileAt url: URL, algorithm: ChecksumAlgorithm) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        switch algorithm {
        case .md5:    return try hash(handle, into: Insecure.MD5())
        case .sha1:   return try hash(handle, into: Insecure.SHA1())
        case .sha256: return try hash(handle, into: SHA256())
        }
    }

    /// Whether the file at `url` matches `expected`. Async so that, when awaited
    /// from an actor, the CPU-bound hashing runs off the actor's executor.
    public static func verify(fileAt url: URL, expected: Checksum) async throws -> Bool {
        let actual = try digest(fileAt: url, algorithm: expected.algorithm)
        return constantTimeEquals(actual, expected.value)
    }

    private static func hash<H: HashFunction>(_ handle: FileHandle, into hasher: H) throws -> String {
        var h = hasher
        while true {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            h.update(data: chunk)
        }
        return h.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Length-checked, branch-stable comparison of two normalized hex strings.
    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in ab.indices { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }
}
