import Foundation

// ============================================================================
// DiagnosticsBundle — a support report the USER sends, not the app.
//
// The product's "no telemetry" promise means we can never learn anything about
// an install unless the user chooses to tell us. This type is the honest way to
// square that with being able to fix bugs: it assembles everything a maintainer
// would ask for — versions, engine states, task counts, configuration — entirely
// in memory, hands it back as text or JSON, and stops. Nothing here writes a
// file, opens a socket, or schedules anything. The user reads it, decides, and
// pastes it into an email themselves.
//
// Because the output is designed to leave the machine, sanitisation is not a
// nicety, it is the entire contract. The rule enforced below is an ALLOW-LIST:
// a setting is included only if it has been individually reviewed and named in
// ``DiagnosticsRedaction/safeSettingsKeys``. A deny-list would have the opposite
// failure mode — every field added to `AppSettings` in future would leak by
// default until someone remembered to block it. ``DiagnosticsTests`` fails the
// build when a new key appears that nobody has classified.
// ============================================================================

/// An in-memory support report, ready for the user to copy or save.
///
/// Build it with ``make(settings:tasks:runningEngineKinds:appVersion:buildNumber:systemVersion:architecture:generatedAt:)``
/// and render it with ``plainText`` or ``jsonData()``. `Codable` so the JSON form
/// round-trips, which is also what makes the redaction assertions testable.
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

    /// Failure counts keyed by the *case name* of the error (`network`,
    /// `http-404`, `timedOut`, …). Never the error's message, which routinely
    /// contains the URL that failed.
    public let failureCountsByStatus: [String: Int]

    /// The sanitised settings dump: allow-listed keys plus derived "is it
    /// configured?" booleans standing in for the fields that are withheld.
    public let settings: [String: String]

    /// Names — never values — of the `AppSettings` fields deliberately withheld.
    /// Listing them keeps the report honest: a maintainer can see that a proxy
    /// *is* configured without learning where it points.
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

    /// Assembles a report from the live queue and configuration.
    ///
    /// Every argument is injectable so the whole thing is testable off a real
    /// app bundle — the defaults read the host environment, which is what the
    /// Settings pane will use.
    ///
    /// - Parameters:
    ///   - settings: The live settings. Only allow-listed keys reach the output.
    ///   - tasks: The whole queue. Only *counts* are derived — no name, URL,
    ///     save path or per-task identifier ever enters the bundle.
    ///   - runningEngineKinds: Which engines the app currently has started.
    ///     Core cannot see this (engines are owned above it), so the caller says.
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

    /// Stable, non-localised status token. Deliberately not
    /// ``DownloadStatus/displayName``, which is user-facing text that
    /// localisation is free to change out from under a log parser.
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

    /// OS name + version. `operatingSystemVersionString` alone is a debug-only
    /// string on Apple platforms, so the numeric version is used and the name
    /// prefixed explicitly.
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

    /// The architecture this binary was *compiled* for. Read from the compiler
    /// rather than `uname`, so a Rosetta-translated build reports the slice that
    /// is actually executing.
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

/// The allow-list, the withheld list, and the string scrubber behind
/// ``DiagnosticsBundle``.
///
/// Every field of ``AppSettings`` is in exactly one of two sets:
///
/// * ``safeSettingsKeys`` — reviewed and judged non-identifying. Emitted, still
///   passed through ``scrub(_:)``.
/// * ``withheldSettingsKeys`` — a secret, a credential, a hostname, a URL, or
///   free-form text a user could have pasted a secret into. Never emitted;
///   summarised instead by a derived `…Configured` boolean where the *fact* of
///   configuration is diagnostically useful.
///
/// Anything absent from both is dropped (fail-closed) *and* trips the coverage
/// assertion in `DiagnosticsTests`, so a new setting cannot slip out unnoticed.
public enum DiagnosticsRedaction {

    /// Reviewed as non-identifying. Booleans, enum tokens, numeric limits, and
    /// filesystem paths (which are emitted only after ``scrub(_:)`` rewrites the
    /// home directory to `~`, since a raw home path carries the account name).
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

    /// Never emitted verbatim. Each entry is here for one of four reasons:
    ///
    /// * **A secret.** `remoteToken`, `remotePasswordHash`.
    /// * **An identity.** `remoteUsername`.
    /// * **A network location.** `proxyHost`, `proxyPort` (together they are the
    ///   proxy's address, and a proxy address is frequently a corporate one that
    ///   identifies the user's employer), `rssFeeds`, `updateFeedURL`.
    /// * **Free-form text a user can paste anything into.** `userAgent`,
    ///   `antivirusArgumentTemplate`, `postDownloadScriptArgs` (all three are
    ///   plausible homes for an API key), and the user-typed profile labels
    ///   `selectedProfileName` / `scheduleProfileName` / `profiles`
    ///   (`aggregationAdapterIds` is withheld as a list rather than a scalar; its
    ///   size is reported instead).
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

    /// Every `AppSettings` key that has been consciously classified. The
    /// coverage test compares this against the type's real encoded keys, so
    /// adding a field to `AppSettings` without deciding its privacy class fails
    /// the suite rather than shipping a leak.
    public static var reviewedSettingsKeys: Set<String> {
        safeSettingsKeys.union(withheldSettingsKeys)
    }

    // MARK: Scrubbing

    /// Rewrites the current user's home directory to `~` and genericises any
    /// other account's home path.
    ///
    /// Two passes, in this order:
    ///
    /// 1. Known home directories (`NSHomeDirectory()` — which is the *container*
    ///    path under App Sandbox — and `homeDirectoryForCurrentUser`) become `~`.
    /// 2. Anything still matching `/Users/<name>` or `/home/<name>` becomes
    ///    `/Users/<user>`. This catches an external volume's copy of a home
    ///    path, a second account, and the sandbox container's *outer* prefix.
    ///
    /// The short account name is then swept up on its own, at word boundaries,
    /// because it can appear outside a path (a hostname like `vinit-mbp`, a
    /// scanner argument). Names shorter than three characters are left alone —
    /// the false-positive rate would ruin the report for no real gain.
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

    /// Produces the sanitised settings dump.
    ///
    /// The allow-listed keys are read back out of the type's *own* `Codable`
    /// encoding rather than by hand, so the dump cannot drift from the real
    /// stored shape; every value is then scrubbed. The withheld keys are
    /// replaced by derived facts that answer "is this configured?" without
    /// answering "configured as what?".
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

    /// Keys actually present in the encoded form of `AppSettings`. Used by the
    /// coverage test; exposed so the assertion reads off the real type instead of
    /// a hand-maintained copy of it.
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

/// A minimal JSON value used to read `AppSettings` back out of its own encoding.
///
/// `JSONSerialization` would be shorter, but it bridges JSON booleans to
/// `NSNumber`, so `true` and `1` become indistinguishable and every flag in the
/// report would print as a digit. `JSONDecoder` keeps the distinction.
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

    /// Report-friendly rendering. Nested objects collapse to `{…}`: no
    /// allow-listed key is an object today, and if one ever becomes one it must
    /// be reviewed field by field rather than dumped wholesale.
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
