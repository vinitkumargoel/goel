import Foundation

/// One of the switchable Low / Medium / High traffic-limit profiles.
/// A value of 0 for a byte/sec cap means "unlimited".
public struct TrafficProfile: Codable, Sendable, Hashable, Identifiable {
    public var id: String { name }
    public var name: String
    public var maxDownloadBytesPerSec: Int64
    public var maxUploadBytesPerSec: Int64
    public var maxConnections: Int
    public var maxConnectionsPerServer: Int
    public var maxSimultaneousDownloads: Int
    public var maxMetadataResolutions: Int
    public var seedRatioLimit: Double
    public var enableExtraConnections: Bool

    public init(
        name: String,
        maxDownloadBytesPerSec: Int64,
        maxUploadBytesPerSec: Int64,
        maxConnections: Int,
        maxConnectionsPerServer: Int,
        maxSimultaneousDownloads: Int,
        maxMetadataResolutions: Int,
        seedRatioLimit: Double,
        enableExtraConnections: Bool
    ) {
        self.name = name
        self.maxDownloadBytesPerSec = maxDownloadBytesPerSec
        self.maxUploadBytesPerSec = maxUploadBytesPerSec
        self.maxConnections = maxConnections
        self.maxConnectionsPerServer = maxConnectionsPerServer
        self.maxSimultaneousDownloads = maxSimultaneousDownloads
        self.maxMetadataResolutions = maxMetadataResolutions
        self.seedRatioLimit = seedRatioLimit
        self.enableExtraConnections = enableExtraConnections
    }

    public var isDownloadUnlimited: Bool { maxDownloadBytesPerSec <= 0 }

    /// Effective per-task download cap (bytes/sec): profile ceiling tightened by an optional task
    /// limit. `0` on either side means unlimited; when both are finite the smaller wins.
    public func effectiveDownloadCap(taskLimit: Int64?) -> Int64 {
        var cap = maxDownloadBytesPerSec
        if let taskLimit, taskLimit > 0 {
            cap = cap == 0 ? taskLimit : min(cap, taskLimit)
        }
        return cap
    }

    private static let MB: Int64 = 1024 * 1024

    public static let low = TrafficProfile(
        name: "Low",
        maxDownloadBytesPerSec: 2 * MB,
        maxUploadBytesPerSec: 256 * 1024,
        maxConnections: 50,
        maxConnectionsPerServer: 4,
        maxSimultaneousDownloads: 2,
        maxMetadataResolutions: 2,
        seedRatioLimit: 1.0,
        enableExtraConnections: false
    )

    public static let medium = TrafficProfile(
        name: "Medium",
        // Default profile, so this cap is what most users silently run under: 10 MiB/s (~84 Mbps)
        // throttled modern broadband unnoticed; 50 MiB/s (~419 Mbps) still limits without doing that.
        maxDownloadBytesPerSec: 50 * MB,
        maxUploadBytesPerSec: 1 * MB,
        maxConnections: 200,
        maxConnectionsPerServer: 8,
        maxSimultaneousDownloads: 5,
        maxMetadataResolutions: 5,
        seedRatioLimit: 1.5,
        enableExtraConnections: true
    )

    public static let high = TrafficProfile(
        name: "High",
        maxDownloadBytesPerSec: 0, // unlimited
        maxUploadBytesPerSec: 5 * MB,
        maxConnections: 500,
        maxConnectionsPerServer: 16,
        maxSimultaneousDownloads: 10,
        maxMetadataResolutions: 8,
        seedRatioLimit: 2.0,
        enableExtraConnections: true
    )

    public static let defaults: [TrafficProfile] = [.low, .medium, .high]
}
