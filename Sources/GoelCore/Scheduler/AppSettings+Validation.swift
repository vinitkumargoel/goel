import Foundation

/// The only clamp before settings reach an engine or arithmetic site — a `0` limit reads *unlimited*.
public extension AppSettings {

    func validated() -> AppSettings {
        var s = self
        s.profiles = s.profiles.map { $0.validated() }
        s.hlsMaxHeight = s.hlsMaxHeight.clamped(to: 0...4320)
        s.proxyPort = s.proxyPort.clamped(to: 0...65_535)
        s.connectionTimeout = s.connectionTimeout.clamped(to: 1...3600, fallback: 30)
        s.retryCount = s.retryCount.clamped(to: 0...20)
        s.retryInterval = s.retryInterval.clamped(to: 0...3600, fallback: 5)
        s.autoRetryMaxAttempts = s.autoRetryMaxAttempts.clamped(to: 0...20)
        s.aggregationStreamsPerAdapter = s.aggregationStreamsPerAdapter.clamped(to: 1...16)
        s.batteryThresholdPercent = s.batteryThresholdPercent.clamped(to: 0...100)
        s.backupIntervalHours = s.backupIntervalHours.clamped(to: 1...8_760)
        s.backupKeepCount = s.backupKeepCount.clamped(to: 1...500)
        s.scheduleStartMinute = s.scheduleStartMinute.clamped(to: 0...1439)
        s.scheduleEndMinute = s.scheduleEndMinute.clamped(to: 0...1439)
        let days = Set(s.scheduleDays.filter { (1...7).contains($0) }).sorted()
        s.scheduleDays = days.isEmpty ? [1, 2, 3, 4, 5, 6, 7] : days
        s.rssPollIntervalMinutes = s.rssPollIntervalMinutes.clamped(to: 5...10_080)
        s.remotePort = s.remotePort.clamped(to: 1...65_535)
        s.remoteSessionMinutes = s.remoteSessionMinutes.clamped(to: 5...43_200)
        s.remoteLoginMaxAttempts = s.remoteLoginMaxAttempts.clamped(to: 1...100)
        s.remoteLoginBackoffSeconds = s.remoteLoginBackoffSeconds.clamped(to: 1...3600, fallback: 5)
        s.auditLogRetentionDays = s.auditLogRetentionDays.clamped(to: 0...3650)
        s.auditLogKeepFiles = s.auditLogKeepFiles.clamped(to: 0...1000)
        s.auditLogMaxFileMegabytes = s.auditLogMaxFileMegabytes.clamped(to: 1...1024)
        // Capped at 8: ffmpeg already uses every core, so more processes just fight each other.
        s.mediaConcurrency = s.mediaConcurrency.clamped(to: 1...8)
        s.language = Self.supportedLanguageName(s.language)
        if s.existingFileReaction != "rename", s.existingFileReaction != "overwrite" {
            s.existingFileReaction = "rename"
        }
        return s
    }

    private static func supportedLanguageName(_ stored: String) -> String {
        if L10n.supportedLanguages.contains(where: { $0.name == stored }) { return stored }
        let code = L10n.languageCode(for: stored)
        return L10n.supportedLanguages.first { $0.code == code }?.name ?? "English"
    }
}

public extension TrafficProfile {

    /// Byte caps floor at 0 = unlimited (the `High` profile relies on it); download count floors at 1, never 0.
    func validated() -> TrafficProfile {
        var p = self
        p.maxDownloadBytesPerSec = max(0, p.maxDownloadBytesPerSec)
        p.maxUploadBytesPerSec = max(0, p.maxUploadBytesPerSec)
        p.maxConnections = p.maxConnections.clamped(to: 1...4096)
        p.maxConnectionsPerServer = p.maxConnectionsPerServer.clamped(to: 1...256)
        p.maxSimultaneousDownloads = p.maxSimultaneousDownloads.clamped(to: 1...100)
        p.maxMetadataResolutions = p.maxMetadataResolutions.clamped(to: 1...100)
        p.seedRatioLimit = p.seedRatioLimit.clamped(to: 0...1000, fallback: 0)
        return p
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private extension Double {
    /// NaN/±∞ has no meaningful clamp and would poison every arithmetic site downstream — hence `fallback`.
    func clamped(to range: ClosedRange<Double>, fallback: Double) -> Double {
        guard isFinite else { return fallback }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
