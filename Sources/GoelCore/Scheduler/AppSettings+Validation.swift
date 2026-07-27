import Foundation

// MARK: - Settings validation

/// The single clamp applied to every settings value before it reaches an engine,
/// a timer, or an arithmetic site.
///
/// Nothing else in the app validates numbers: the Settings panes are plain
/// `TextField(value:format:.number)` controls, the remote API decodes JSON
/// straight into ``AppSettings``, and a restored backup is whatever the file
/// said. Without a boundary a `0` simultaneous-download limit reads as
/// *unlimited* to ``SchedulingPolicy`` (whose documented contract that is), a
/// thirteen-digit "rotate at MB" traps on `Int` multiplication, and a negative
/// timeout is handed to `URLSession`.
///
/// ``AppSettings/validated()`` is that boundary. Every default sits inside its
/// range, so no existing install moves; ``SchedulingPolicy`` keeps its
/// "0 means unlimited" contract untouched — the point is that `0` can no longer
/// *reach* it from settings.
public extension AppSettings {

    /// This settings value with every numeric field clamped into its supported
    /// range and every enum-like string coerced to a value the app implements.
    ///
    /// Ranges:
    /// - `hlsMaxHeight` `0…4320` (0 = best available)
    /// - `proxyPort` `0…65535` (0 = unset)
    /// - `connectionTimeout` `1…3600` seconds
    /// - `retryCount` `0…20`, `retryInterval` `0…3600` seconds
    /// - `autoRetryMaxAttempts` `0…20`
    /// - `aggregationStreamsPerAdapter` `1…16`
    /// - `batteryThresholdPercent` `0…100`
    /// - `backupIntervalHours` `1…8760` (a year), `backupKeepCount` `1…500`
    /// - `scheduleStartMinute` / `scheduleEndMinute` `0…1439`
    /// - `scheduleDays` filtered to `1…7`, de-duplicated and sorted; an empty
    ///   result becomes every day (a schedule that matches nothing would pause
    ///   the queue forever)
    /// - `rssPollIntervalMinutes` `5…10080` (a week)
    /// - `remotePort` `1…65535`, `remoteSessionMinutes` `5…43200` (30 days)
    /// - `remoteLoginMaxAttempts` `1…100`, `remoteLoginBackoffSeconds` `1…3600`
    /// - `auditLogRetentionDays` `0…3650` (0 = no age pruning),
    ///   `auditLogKeepFiles` `0…1000`, `auditLogMaxFileMegabytes` `1…1024`
    ///
    /// String coercions:
    /// - `language` must name a language that ships a strings table
    ///   (``L10n/supportedLanguages``); anything else resolves through
    ///   ``L10n/languageCode(for:)`` back to a supported name, falling back to
    ///   English. A persisted value from an older build that offered languages
    ///   with no table would otherwise render an empty picker.
    /// - `existingFileReaction` must be `rename` or `overwrite`; anything else
    ///   becomes `rename`, the non-destructive option.
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
        // Upper bound as well as lower: every ffmpeg spreads itself across all
        // cores, so a hand-edited settings file asking for 64 at once would spawn
        // 64 processes that fight each other and finish the batch no sooner.
        s.mediaConcurrency = s.mediaConcurrency.clamped(to: 1...8)
        s.language = Self.supportedLanguageName(s.language)
        if s.existingFileReaction != "rename", s.existingFileReaction != "overwrite" {
            s.existingFileReaction = "rename"
        }
        return s
    }

    /// The supported-language *name* a stored value resolves to. A name already in
    /// ``L10n/supportedLanguages`` is kept verbatim; anything else goes through
    /// ``L10n/languageCode(for:)`` (which knows the aliases) and back to the
    /// matching name, defaulting to English.
    private static func supportedLanguageName(_ stored: String) -> String {
        if L10n.supportedLanguages.contains(where: { $0.name == stored }) { return stored }
        let code = L10n.languageCode(for: stored)
        return L10n.supportedLanguages.first { $0.code == code }?.name ?? "English"
    }
}

public extension TrafficProfile {

    /// This profile with every limit clamped into its supported range.
    ///
    /// Ranges:
    /// - `maxDownloadBytesPerSec` / `maxUploadBytesPerSec` `≥ 0`; `0` keeps its
    ///   meaning of *unlimited* — that is the documented contract of a byte cap
    ///   and the `High` profile relies on it.
    /// - `maxConnections` `1…4096`, `maxConnectionsPerServer` `1…256`
    /// - `maxSimultaneousDownloads` `1…100`. This is the semantic fix: a `0`
    ///   here means "unlimited" to ``SchedulingPolicy``, which is the opposite of
    ///   what a user typing `0` into "Max simultaneous downloads" expects. Zero
    ///   can no longer arrive from settings, so the policy's own contract is left
    ///   alone.
    /// - `maxMetadataResolutions` `1…100`
    /// - `seedRatioLimit` `0…1000`; a non-finite value (NaN/∞ from a hand-edited
    ///   JSON) becomes `0`, i.e. no ratio target.
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
    /// `self` pulled into `range`. Total — no trapping, no optionals.
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private extension Double {
    /// `self` pulled into `range`, substituting `fallback` for NaN/±∞ — a
    /// non-finite value has no meaningful clamp and would poison every
    /// arithmetic site downstream.
    func clamped(to range: ClosedRange<Double>, fallback: Double) -> Double {
        guard isFinite else { return fallback }
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
