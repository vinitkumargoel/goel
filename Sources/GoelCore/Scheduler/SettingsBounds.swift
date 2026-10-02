import Foundation

/// Allowed ranges for the numeric settings: the single source for `AppSettings.validated()`
/// (which clamps to them) and for the Settings fields (which show them and warn on a clamp).
public enum SettingsBounds {
    public static let hlsMaxHeight = 0...4320
    public static let proxyPort = 0...65_535
    public static let connectionTimeout = 1.0...3600.0
    public static let retryCount = 0...20
    public static let retryInterval = 0.0...3600.0
    public static let autoRetryMaxAttempts = 0...20
    public static let aggregationStreamsPerAdapter = 1...16
    public static let batteryThresholdPercent = 0...100
    public static let backupIntervalHours = 1...8_760
    public static let backupKeepCount = 1...500
    public static let rssPollIntervalMinutes = 5...10_080
    public static let remotePort = 1...65_535
    public static let remoteSessionMinutes = 5...43_200
    public static let remoteLoginMaxAttempts = 1...100
    public static let remoteLoginBackoffSeconds = 1.0...3600.0
    public static let auditLogRetentionDays = 0...3650
    public static let auditLogKeepFiles = 0...1000
    public static let auditLogMaxFileMegabytes = 1...1024
    public static let mediaConcurrency = 1...8

    /// Per-profile speed caps, in MB/s as typed (the model stores bytes).
    public static let profileSpeedMegabytes = 0.0...1_048_576.0

    // Per traffic profile.
    public static let profileMaxConnections = 1...4096
    public static let profileMaxConnectionsPerServer = 1...256
    public static let profileMaxSimultaneousDownloads = 1...100
    public static let profileMaxMetadataResolutions = 1...100
    public static let profileSeedRatioLimit = 0.0...1000.0

    /// A typed value pulled into `range`, and whether that changed it.
    public static func clamp<T: Comparable>(_ value: T, to range: ClosedRange<T>) -> (value: T, wasClamped: Bool) {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        return (clamped, clamped != value)
    }
}
