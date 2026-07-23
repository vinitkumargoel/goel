import Foundation

// The checksum *value types* — algorithm + expected digest — kept apart from the
// CryptoKit-backed `ChecksumVerifier` (which does the actual hashing and disk I/O,
// in `ChecksumVerifier.swift`). Splitting them lets these pure, Foundation-only
// types live in the platform-free contract layer while the hashing engine stays
// behind, since a `Checksum` travels through the domain model and wire DTOs.

/// A file-integrity hash algorithm the verifier understands.
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

    /// The number of hex characters a digest of this algorithm produces, used to
    /// auto-detect the algorithm from a pasted hash.
    public var hexLength: Int {
        switch self {
        case .md5: return 32
        case .sha1: return 40
        case .sha256: return 64
        case .sha512: return 128
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
