import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// The `Checksum` / `ChecksumAlgorithm` value types live in `Model/Checksum.swift`
// (platform-free). This file keeps the hashing engine, which needs CryptoKit and
// on-disk streaming and therefore stays in the engine layer.

/// Streams a file through a hash function and compares it to an expected digest.
///
/// Reads in fixed windows so multi-gigabyte files never load fully into memory,
/// and checks for cancellation between chunks so a removed/paused task stops
/// hashing promptly.
enum ChecksumVerifier {
    /// Read window: 1 MiB.
    static let chunkSize = 1 << 20

    /// Compute the lowercase hex digest of the file at `url` using `algorithm`.
    static func digest(fileAt url: URL, algorithm: ChecksumAlgorithm) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        switch algorithm {
        case .md5:    return try hash(handle, into: Insecure.MD5())
        case .sha1:   return try hash(handle, into: Insecure.SHA1())
        case .sha256: return try hash(handle, into: SHA256())
        case .sha512: return try hash(handle, into: SHA512())
        }
    }

    /// Whether the file at `url` matches `expected`. Async so that, when awaited
    /// from an actor, the CPU-bound hashing runs off the actor's executor.
    static func verify(fileAt url: URL, expected: Checksum) async throws -> Bool {
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
