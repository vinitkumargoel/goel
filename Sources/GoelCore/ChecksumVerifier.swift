import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

public enum ChecksumAlgorithm: String, Codable, Sendable, CaseIterable, Hashable {
    case md5
    case sha1
    case sha256
    case sha512

    public var displayName: String {
        switch self {
        case .md5: return "MD5"
        case .sha1: return "SHA-1"
        case .sha256: return "SHA-256"
        case .sha512: return "SHA-512"
        }
    }

    public var hexLength: Int {
        switch self {
        case .md5: return 32
        case .sha1: return 40
        case .sha256: return 64
        case .sha512: return 128
        }
    }
}

public struct Checksum: Codable, Sendable, Hashable {
    public var algorithm: ChecksumAlgorithm
    public var value: String

    public init(algorithm: ChecksumAlgorithm, value: String) {
        self.algorithm = algorithm
        self.value = Checksum.normalize(value)
    }

    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

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

enum ChecksumVerifier {
    static let chunkSize = 1 << 20

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

    /// `async` so the CPU-bound hashing runs off a calling actor's executor.
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

    /// Constant-time: branch-stable, no early exit — do not replace with `==`.
    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8), bb = Array(b.utf8)
        guard ab.count == bb.count else { return false }
        var diff: UInt8 = 0
        for i in ab.indices { diff |= ab[i] ^ bb[i] }
        return diff == 0
    }
}
