import Foundation

// DiagnosticsBundle — a support report the USER sends, not the app ("no telemetry"): built in memory,
// never written or transmitted. Sanitisation is an ALLOW-LIST; a deny-list would leak each new field.

/// In-memory support report, ready to copy or save: build via ``make(settings:tasks:runningEngineKinds:…)``,
/// render via ``plainText`` or ``jsonData()``. `Codable` so JSON round-trips, making redaction testable.
public struct DiagnosticsBundle: Codable, Sendable, Equatable {

    /// One engine's liveness plus how much work it currently owns.
    public struct EngineState: Codable, Sendable, Equatable {
        /// The engine's `DownloadKind` raw value (`http`, `torrent`, …).
        public let kind: String
        /// Whether the app currently has this engine instantiated and started.
        public let isRunning: Bool
        /// Tasks of this kind in an active state (downloading/verifying/seeding/…).
        public let activeTaskCount: Int
        /// Tasks of this kind in the queue at all, in any state.
        public let totalTaskCount: Int

        public init(kind: String, isRunning: Bool, activeTaskCount: Int, totalTaskCount: Int) {
            self.kind = kind
            self.isRunning = isRunning
            self.activeTaskCount = activeTaskCount
            self.totalTaskCount = totalTaskCount
        }
    }

    /// When the report was assembled (UTC when rendered).
    public let generatedAt: Date

    /// Marketing version, e.g. `1.4.2`. `"unknown"` outside an app bundle.
    public let appVersion: String

    /// Build number, e.g. `412`. `"unknown"` outside an app bundle.
    public let buildNumber: String

    /// OS name and version, e.g. `macOS 14.5.0`.
    public let systemVersion: String

    /// CPU architecture the binary was compiled for (`arm64` / `x86_64`).
    public let architecture: String

    /// Per-engine liveness, in a stable order.
    public let engineStates: [EngineState]

    /// How many tasks the queue holds in total.
    public let totalTaskCount: Int

    /// Task counts keyed by status name (`queued`, `downloading`, `failed`, …).
    /// Only states that occur are present.
    public let taskCountsByStatus: [String: Int]

    /// Failure counts keyed by the error's *case name* (`network`, `http-404`, `timedOut`, …) — never
    /// its message, which routinely contains the URL that failed.
    public let failureCountsByStatus: [String: Int]

    /// The sanitised settings dump: allow-listed keys plus derived "is it
    /// configured?" booleans standing in for the fields that are withheld.
    public let settings: [String: String]

    /// Names — never values — of the deliberately withheld `AppSettings` fields, so a maintainer can
    /// see that a proxy *is* configured without learning where it points.
    public let withheldSettingKeys: [String]

    public init(
        generatedAt: Date,
        appVersion: String,
        buildNumber: String,
        systemVersion: String,
        architecture: String,
        engineStates: [EngineState],
        totalTaskCount: Int,
        taskCountsByStatus: [String: Int],
        failureCountsByStatus: [String: Int],
        settings: [String: String],
        withheldSettingKeys: [String]
    ) {
        self.generatedAt = generatedAt
        self.appVersion = appVersion
        self.buildNumber = buildNumber
        self.systemVersion = systemVersion
        self.architecture = architecture
        self.engineStates = engineStates
        self.totalTaskCount = totalTaskCount
        self.taskCountsByStatus = taskCountsByStatus
        self.failureCountsByStatus = failureCountsByStatus
        self.settings = settings
        self.withheldSettingKeys = withheldSettingKeys
    }
}

// MARK: - Assembly

public extension DiagnosticsBundle {

    /// Assembles a report. `settings` yields allow-listed keys only; `tasks` yields *counts* only (no
    /// name/URL/path); `runningEngineKinds` is caller-supplied since Core cannot see engines. All injectable.
    static func make(
        settings: AppSettings,
        tasks: [DownloadTask],
        runningEngineKinds: Set<DownloadKind> = [],
        appVersion: String = DiagnosticsBundle.hostAppVersion,
        buildNumber: String = DiagnosticsBundle.hostBuildNumber,
        systemVersion: String = DiagnosticsBundle.hostSystemVersion,
        architecture: String = DiagnosticsBundle.hostArchitecture,
        generatedAt: Date = Date()
    ) -> DiagnosticsBundle {

        var statusCounts: [String: Int] = [:]
        var failureCounts: [String: Int] = [:]
        var activePerKind: [DownloadKind: Int] = [:]
        var totalPerKind: [DownloadKind: Int] = [:]

        for task in tasks {
            statusCounts[Self.statusLabel(task.status), default: 0] += 1
            if case .failed(let error) = task.status {
                failureCounts[DiagnosticsErrorLabel.of(error), default: 0] += 1
            }
            let kind = task.source.kind
            totalPerKind[kind, default: 0] += 1
            if task.status.isActive { activePerKind[kind, default: 0] += 1 }
        }

        let engineStates = DownloadKind.allCases.map { kind in
            EngineState(
                kind: kind.rawValue,
                isRunning: runningEngineKinds.contains(kind),
                activeTaskCount: activePerKind[kind] ?? 0,
                totalTaskCount: totalPerKind[kind] ?? 0
            )
        }

        return DiagnosticsBundle(
            generatedAt: generatedAt,
            appVersion: appVersion,
            buildNumber: buildNumber,
            systemVersion: systemVersion,
            architecture: architecture,
            engineStates: engineStates,
            totalTaskCount: tasks.count,
            taskCountsByStatus: statusCounts,
            failureCountsByStatus: failureCounts,
            settings: DiagnosticsRedaction.sanitisedSettings(settings),
            withheldSettingKeys: DiagnosticsRedaction.withheldSettingsKeys.sorted()
        )
    }

    /// Stable, non-localised status token — deliberately not ``DownloadStatus/displayName``, which is
    /// user-facing text localisation may change out from under a log parser.
    static func statusLabel(_ status: DownloadStatus) -> String {
        switch status {
        case .queued:             return "queued"
        case .requestingMetadata: return "requestingMetadata"
        case .downloading:        return "downloading"
        case .verifying:          return "verifying"
        case .paused:             return "paused"
        case .seeding:            return "seeding"
        case .completed:          return "completed"
        case .failed:             return "failed"
        }
    }

    // MARK: Host facts

    /// `CFBundleShortVersionString`, or `"unknown"` when there is no bundle
    /// (SwiftPM test runs, the Linux daemon).
    static var hostAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    /// `CFBundleVersion`, or `"unknown"` outside a bundle.
    static var hostBuildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    }

    /// OS name + version. `operatingSystemVersionString` is debug-only on Apple platforms, so the
    /// numeric version is used and the name prefixed explicitly.
    static var hostSystemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let number = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        #if os(macOS)
        return "macOS \(number)"
        #elseif os(Linux)
        return "Linux \(number)"
        #else
        return number
        #endif
    }

    /// Architecture this binary was *compiled* for — read from the compiler, not `uname`, so a
    /// Rosetta-translated build reports the slice that is actually executing.
    static var hostArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

// MARK: - Rendering

public extension DiagnosticsBundle {

    /// A human-readable report — the form the Settings pane shows and the user
    /// copies into an email.
    var plainText: String {
        var out = ""
        out += "Goel° diagnostics report\n"
        out += "This report was generated on your Mac and has not been sent anywhere.\n"
        out += "Secrets, URLs, file names and account details are excluded by design.\n"
        out += "\n"
        out += "Generated       \(Self.timestampFormatter.string(from: generatedAt))\n"
        out += "App version     \(appVersion) (\(buildNumber))\n"
        out += "System          \(systemVersion)\n"
        out += "Architecture    \(architecture)\n"
        out += "\n"

        out += "── Engines ──\n"
        for state in engineStates {
            let running = state.isRunning ? "running" : "stopped"
            out += "\(state.kind.padded(to: 10)) \(running.padded(to: 8)) active \(state.activeTaskCount), total \(state.totalTaskCount)\n"
        }
        out += "\n"

        out += "── Tasks (\(totalTaskCount) total) ──\n"
        if taskCountsByStatus.isEmpty {
            out += "(queue is empty)\n"
        } else {
            for (status, count) in taskCountsByStatus.sorted(by: { $0.key < $1.key }) {
                out += "\(status.padded(to: 20)) \(count)\n"
            }
        }
        out += "\n"

        if !failureCountsByStatus.isEmpty {
            out += "── Failures by reason ──\n"
            for (reason, count) in failureCountsByStatus.sorted(by: { $0.key < $1.key }) {
                out += "\(reason.padded(to: 20)) \(count)\n"
            }
            out += "\n"
        }

        out += "── Settings (sanitised) ──\n"
        for (key, value) in settings.sorted(by: { $0.key < $1.key }) {
            out += "\(key.padded(to: 36)) \(value)\n"
        }
        out += "\n"

        out += "── Withheld (names only; values never leave the app) ──\n"
        out += withheldSettingKeys.joined(separator: ", ")
        out += "\n"
        return out
    }

    /// The machine-readable form, for a user who prefers to attach a file.
    /// Sorted keys and ISO-8601 dates so two reports diff cleanly.
    func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    private static var timestampFormatter: ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }
}

private extension String {
    /// Left-aligned column padding for the plain-text report.
    func padded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}

// MARK: - Redaction

/// Allow-list ``safeSettingsKeys`` (emitted, still scrubbed) vs ``withheldSettingsKeys`` (summarised as a
/// `…Configured` bool). A key in neither is dropped fail-closed *and* trips the `DiagnosticsTests` check.
public enum DiagnosticsRedaction {

    /// Reviewed as non-identifying: booleans, enum tokens, numeric limits, and paths — paths only after
    /// ``scrub(_:)`` rewrites home to `~`, since a raw home path carries the account name.
    public static let safeSettingsKeys: Set<String> = [
        // Traffic
        "speedLimitEnabled", "defaultSaveDirectory",
        // General
        "theme", "language", "launchAtLogin", "launchMinimized", "menuBarExtraEnabled",
        "defaultFolderRule", "existingFileReaction", "clipboardMonitorEnabled",
        "hlsMaxHeight", "detailPanelPosition",
        // Network
        "proxyMode", "proxyType", "proxyAllProtocols", "connectionTimeout",
        "retryCount", "retryInterval", "autoRetryEnabled", "autoRetryMaxAttempts",
        "cookieAuthEnabled",
        // Network aggregation
        "aggregationEnabled", "aggregationIncludeExpensive", "aggregationAllowOutsideVPN",
        "aggregationStreamsPerAdapter", "aggregationStrategy", "aggregationPathDiversityProbe",
        // BitTorrent
        "btMakeDefaultClient", "btAutoDeleteTorrent", "btWatchFolderEnabled",
        "btWatchFolderPath", "btWatchStartWithoutConfirmation", "btEncryptionMode",
        "btEnableDHT", "btEnablePeX", "btEnableLPD", "btEnableUTP",
        // Notifications
        "notifyOnAdded", "notifyOnCompleted", "notifyOnFailed",
        "notifyOnlyWhenInactive", "notificationSound",
        // Power
        "preventSleepWhileDownloading", "allowSleepIfResumable", "allowSleepWhileSeeding",
        "pauseBelowBatteryThreshold", "batteryThresholdPercent", "dontSeedOnBattery",
        // Backup
        "backupEnabled", "backupIntervalHours", "backupKeepCount",
        // Antivirus
        "antivirusEnabled", "antivirusScanner", "antivirusExecutablePath",
        // Queue automation
        "autoShutdownAction", "scheduleEnabled", "scheduleStartMinute",
        "scheduleEndMinute", "scheduleDays",
        // Network awareness
        "pauseOnExpensiveNetwork", "pauseOnConstrainedNetwork",
        // Post-download actions
        "postDownloadExtractArchives", "postDownloadScriptEnabled", "postDownloadScriptPath",
        // Media tools
        "autoRedownloadOnRemoteChange", "subtitleDownloadEnabled",
        "subtitleLanguages", "subtitleIncludeAutoGenerated", "ffmpegPath",
        "mediaConcurrency",
        // Remote access (the switches, never the credentials)
        "remoteAccessEnabled", "remotePort", "remoteAllowLAN", "remoteRequireAuth",
        "remoteReadOnly", "remoteSessionMinutes", "remoteTheme",
        // Portal hardening: booleans, numeric limits, a header name, and one
        // path that scrub() already rewrites. None of them name a person.
        "remoteTLSEnabled", "remoteTLSIdentityPath",
        "remoteLoginMaxAttempts", "remoteLoginBackoffSeconds",
        "remoteTrustedHeaderAuthEnabled", "remoteTrustedHeaderName",
        // Audit log: switches, retention limits, and a path scrub() rewrites.
        "auditLogEnabled", "auditLogDirectory", "auditLogRetentionDays",
        "auditLogKeepFiles", "auditLogMaxFileMegabytes",
        // RSS
        "rssPollIntervalMinutes",
        // Updates
        "autoCheckUpdates",
    ]

    /// Never emitted verbatim: secrets, identities, network locations (a proxy or feed address routinely
    /// names the employer), and free-form text a user could have pasted an API key or own label into.
    public static let withheldSettingsKeys: Set<String> = [
        "profiles", "selectedProfileName",
        "proxyHost", "proxyPort",
        "userAgent",
        "aggregationAdapterIds",
        "antivirusArgumentTemplate",
        "scheduleProfileName",
        "postDownloadScriptArgs",
        "remoteToken", "remoteUsername", "remotePasswordHash",
        "rssFeeds",
        "updateFeedURL",
        // A list of internal IPs/CIDRs is a network location, withheld for the
        // same reason as `proxyHost`: it identifies the user's employer.
        "remoteTrustedProxies",
    ]

    /// Every consciously classified `AppSettings` key. The coverage test diffs this against the type's
    /// real encoded keys, so a field added without a privacy class fails the suite instead of leaking.
    public static var reviewedSettingsKeys: Set<String> {
        safeSettingsKeys.union(withheldSettingsKeys)
    }

    // MARK: Scrubbing

    /// Known home dirs (incl. the App Sandbox container) → `~`, then leftover `/Users/<name>`, `/home/<name>`
    /// → `<user>`, then the bare account name at word boundaries — skipped under 3 chars (false positives).
    public static func scrub(_ value: String) -> String {
        var scrubbed = value

        for home in homeDirectoryCandidates where !home.isEmpty {
            scrubbed = scrubbed.replacingOccurrences(of: home, with: "~")
        }

        scrubbed = scrubbed.replacingOccurrences(
            of: #"(/Users/|/home/)[^/\s"']+"#,
            with: "$1<user>",
            options: .regularExpression
        )

        let account = NSUserName()
        if account.count >= 3 {
            scrubbed = scrubbed.replacingOccurrences(
                of: "\\b\(NSRegularExpression.escapedPattern(for: account))\\b",
                with: "<user>",
                options: [.regularExpression, .caseInsensitive]
            )
        }

        return scrubbed
    }

    /// Longest-first so `/Users/me/Library/Containers/app/Data` is matched
    /// before the plain `/Users/me` that is a prefix of it.
    private static var homeDirectoryCandidates: [String] {
        let paths = [NSHomeDirectory(), FileManager.default.homeDirectoryForCurrentUser.path]
        return Array(Set(paths)).sorted { $0.count > $1.count }
    }

    // MARK: Settings projection

    /// Sanitised settings dump: allow-listed keys read out of the type's *own* `Codable` encoding (so it
    /// cannot drift) then scrubbed; withheld keys become "is this configured?" facts, never "as what?".
    public static func sanitisedSettings(_ settings: AppSettings) -> [String: String] {
        var dump: [String: String] = [:]

        for (key, value) in encodedFields(of: settings) where safeSettingsKeys.contains(key) {
            dump[key] = scrub(value.displayText)
        }

        // Derived stand-ins for the withheld fields. Booleans and counts only —
        // never a length or a prefix, which would narrow a secret's search space.
        let profile = settings.effectiveProfile
        dump["profileCount"] = String(settings.profiles.count)
        dump["effectiveMaxDownloadBytesPerSec"] = String(profile.maxDownloadBytesPerSec)
        dump["effectiveMaxUploadBytesPerSec"] = String(profile.maxUploadBytesPerSec)
        dump["effectiveMaxConnections"] = String(profile.maxConnections)
        dump["effectiveMaxConnectionsPerServer"] = String(profile.maxConnectionsPerServer)
        dump["effectiveMaxSimultaneousDownloads"] = String(profile.maxSimultaneousDownloads)

        dump["proxyConfigured"] = boolText(!settings.proxyHost.isEmpty && settings.proxyPort > 0)
        dump["userAgentIsCustom"] = boolText(settings.userAgent != AppSettings().userAgent)
        dump["aggregationAdapterCount"] = String(settings.aggregationAdapterIds.count)
        dump["antivirusArgumentsCustomised"] =
            boolText(settings.antivirusArgumentTemplate != AppSettings().antivirusArgumentTemplate)
        dump["scheduleProfileConfigured"] = boolText(!settings.scheduleProfileName.isEmpty)
        dump["postDownloadScriptArgsCustomised"] =
            boolText(settings.postDownloadScriptArgs != AppSettings().postDownloadScriptArgs)
        dump["remoteTokenConfigured"] = boolText(!settings.remoteToken.isEmpty)
        dump["remoteUsernameConfigured"] = boolText(!settings.remoteUsername.isEmpty)
        dump["remotePasswordConfigured"] = boolText(!settings.remotePasswordHash.isEmpty)
        dump["rssFeedCount"] = String(settings.rssFeeds.count)
        dump["rssFeedEnabledCount"] = String(settings.rssFeeds.filter(\.enabled).count)
        dump["updateFeedIsCustom"] = boolText(!settings.updateFeedURL.isEmpty)

        return dump
    }

    /// Keys actually present in the encoded form of `AppSettings`. Exposed so the coverage test asserts
    /// against the real type instead of a hand-maintained copy of it.
    public static func encodedSettingsKeys(of settings: AppSettings = AppSettings()) -> Set<String> {
        Set(encodedFields(of: settings).keys)
    }

    private static func boolText(_ value: Bool) -> String { value ? "true" : "false" }

    private static func encodedFields(of settings: AppSettings) -> [String: DiagnosticsJSONValue] {
        guard let data = try? JSONEncoder().encode(settings),
              let fields = try? JSONDecoder().decode([String: DiagnosticsJSONValue].self, from: data)
        else { return [:] }
        return fields
    }
}

/// Minimal JSON value used to read `AppSettings` back out of its own encoding. Not `JSONSerialization`:
/// it bridges JSON booleans to `NSNumber`, so `true` and `1` collapse and every flag prints as a digit.
private enum DiagnosticsJSONValue: Decodable {
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([DiagnosticsJSONValue])
    case object([String: DiagnosticsJSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let v = try? container.decode(Bool.self) { self = .bool(v); return }
        if let v = try? container.decode(Int.self) { self = .integer(v); return }
        if let v = try? container.decode(Double.self) { self = .number(v); return }
        if let v = try? container.decode(String.self) { self = .string(v); return }
        if let v = try? container.decode([DiagnosticsJSONValue].self) { self = .array(v); return }
        if let v = try? container.decode([String: DiagnosticsJSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "unsupported JSON value")
    }

    /// Report-friendly rendering. Nested objects collapse to `{…}` — no allow-listed key is an object
    /// today, and one that becomes one must be reviewed field by field rather than dumped wholesale.
    var displayText: String {
        switch self {
        case .bool(let v):    return v ? "true" : "false"
        case .integer(let v): return String(v)
        case .number(let v):  return v == v.rounded() ? String(Int(v)) : String(v)
        case .string(let v):  return v
        case .array(let v):   return v.map(\.displayText).joined(separator: ", ")
        case .object:         return "{…}"
        case .null:           return "null"
        }
    }
}
