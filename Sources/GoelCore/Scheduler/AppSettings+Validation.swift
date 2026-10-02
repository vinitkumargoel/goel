import Foundation

/// The only clamp before settings reach an engine or arithmetic site — a `0` limit reads *unlimited*.
public extension AppSettings {

    func validated() -> AppSettings {
        var s = self
        s.profiles = s.profiles.map { $0.validated() }
        s.hlsMaxHeight = s.hlsMaxHeight.clamped(to: SettingsBounds.hlsMaxHeight)
        s.proxyPort = s.proxyPort.clamped(to: SettingsBounds.proxyPort)
        s.connectionTimeout = s.connectionTimeout.clamped(to: SettingsBounds.connectionTimeout, fallback: 30)
        s.retryCount = s.retryCount.clamped(to: SettingsBounds.retryCount)
        s.retryInterval = s.retryInterval.clamped(to: SettingsBounds.retryInterval, fallback: 5)
        s.autoRetryMaxAttempts = s.autoRetryMaxAttempts.clamped(to: SettingsBounds.autoRetryMaxAttempts)
        s.aggregationStreamsPerAdapter = s.aggregationStreamsPerAdapter.clamped(to: SettingsBounds.aggregationStreamsPerAdapter)
        s.batteryThresholdPercent = s.batteryThresholdPercent.clamped(to: SettingsBounds.batteryThresholdPercent)
        s.backupIntervalHours = s.backupIntervalHours.clamped(to: SettingsBounds.backupIntervalHours)
        s.backupKeepCount = s.backupKeepCount.clamped(to: SettingsBounds.backupKeepCount)
        s.scheduleStartMinute = s.scheduleStartMinute.clamped(to: 0...1439)
        s.scheduleEndMinute = s.scheduleEndMinute.clamped(to: 0...1439)
        let days = Set(s.scheduleDays.filter { (1...7).contains($0) }).sorted()
        s.scheduleDays = days.isEmpty ? [1, 2, 3, 4, 5, 6, 7] : days
        s.rssPollIntervalMinutes = s.rssPollIntervalMinutes.clamped(to: SettingsBounds.rssPollIntervalMinutes)
        s.remotePort = s.remotePort.clamped(to: SettingsBounds.remotePort)
        s.remoteSessionMinutes = s.remoteSessionMinutes.clamped(to: SettingsBounds.remoteSessionMinutes)
        s.remoteLoginMaxAttempts = s.remoteLoginMaxAttempts.clamped(to: SettingsBounds.remoteLoginMaxAttempts)
        s.remoteLoginBackoffSeconds = s.remoteLoginBackoffSeconds.clamped(to: SettingsBounds.remoteLoginBackoffSeconds, fallback: 5)
        s.remoteAllowedHostNames = Self.normalizedHostNames(s.remoteAllowedHostNames)
        s.auditLogRetentionDays = s.auditLogRetentionDays.clamped(to: SettingsBounds.auditLogRetentionDays)
        s.auditLogKeepFiles = s.auditLogKeepFiles.clamped(to: SettingsBounds.auditLogKeepFiles)
        s.auditLogMaxFileMegabytes = s.auditLogMaxFileMegabytes.clamped(to: SettingsBounds.auditLogMaxFileMegabytes)
        // Capped at 8: ffmpeg already uses every core, so more processes just fight each other.
        s.mediaConcurrency = s.mediaConcurrency.clamped(to: SettingsBounds.mediaConcurrency)
        s.language = Self.supportedLanguageName(s.language)
        if s.existingFileReaction != "rename", s.existingFileReaction != "overwrite" {
            s.existingFileReaction = "rename"
        }
        // An unknown action (a typo, an import, a newer build) must never be carried around as a live value.
        s.autoShutdownAction = s.autoShutdown.rawValue
        return s
    }

    static let maxAllowedHostNames = 32

    /// People paste URLs: `https://Goel.Home:8899/` must become `goel.home`, or the Host check never matches.
    /// Anything that still is not a plain name (or `*.suffix`) is dropped rather than half-trusted.
    static func normalizedHostNames(_ raw: [String]) -> [String] {
        var out: [String] = []
        for entry in raw {
            var name = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let scheme = name.range(of: "://") { name = String(name[scheme.upperBound...]) }
            if let slash = name.firstIndex(of: "/") { name = String(name[..<slash]) }
            if let at = name.lastIndex(of: "@") { name = String(name[name.index(after: at)...]) }
            // IP literals always pass the Host check, so a bracketed v6 entry is simply dropped below.
            if name.filter({ $0 == ":" }).count == 1, let colon = name.firstIndex(of: ":") {
                name = String(name[..<colon])
            }
            if name.hasSuffix(".") { name.removeLast() }
            let body = name.hasPrefix("*.") ? String(name.dropFirst(2)) : name
            let legal = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
            guard !body.isEmpty, body.count <= 253, !body.hasPrefix("."),
                  body.unicodeScalars.allSatisfy(legal.contains),
                  !out.contains(name) else { continue }
            out.append(name)
            if out.count == maxAllowedHostNames { break }
        }
        return out
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
        p.maxConnections = p.maxConnections.clamped(to: SettingsBounds.profileMaxConnections)
        p.maxConnectionsPerServer = p.maxConnectionsPerServer.clamped(to: SettingsBounds.profileMaxConnectionsPerServer)
        p.maxSimultaneousDownloads = p.maxSimultaneousDownloads.clamped(to: SettingsBounds.profileMaxSimultaneousDownloads)
        p.maxMetadataResolutions = p.maxMetadataResolutions.clamped(to: SettingsBounds.profileMaxMetadataResolutions)
        p.seedRatioLimit = p.seedRatioLimit.clamped(to: SettingsBounds.profileSeedRatioLimit, fallback: 0)
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
