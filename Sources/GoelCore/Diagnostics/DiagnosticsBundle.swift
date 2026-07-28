import Foundation

// Built in memory, never written or transmitted; sanitisation is an ALLOW-LIST, because a deny-list leaks every new field.

public struct DiagnosticsBundle: Codable, Sendable, Equatable {

    public struct EngineState: Codable, Sendable, Equatable {
        public let kind: String
        public let isRunning: Bool
        public let activeTaskCount: Int
        public let totalTaskCount: Int

        public init(kind: String, isRunning: Bool, activeTaskCount: Int, totalTaskCount: Int) {
            self.kind = kind
            self.isRunning = isRunning
            self.activeTaskCount = activeTaskCount
            self.totalTaskCount = totalTaskCount
        }
    }

    public let generatedAt: Date

    public let appVersion: String

    public let buildNumber: String

    public let systemVersion: String

    public let architecture: String

    public let engineStates: [EngineState]

    public let totalTaskCount: Int

    public let taskCountsByStatus: [String: Int]

    /// Keyed by the error's *case name*, never its message, which routinely contains the URL that failed.
    public let failureCountsByStatus: [String: Int]

    public let settings: [String: String]

    /// Names — never values — of the withheld `AppSettings` fields: a maintainer sees a proxy is configured, not where it points.
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

public extension DiagnosticsBundle {

    /// `settings` yields allow-listed keys only and `tasks` yields *counts* only — no name, URL or path.
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

    /// Not ``DownloadStatus/displayName``: that is user-facing text localisation may change out from under a log parser.
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

    static var hostAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    static var hostBuildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
    }

    /// `operatingSystemVersionString` is debug-only on Apple platforms, so build the string from the numeric version.
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

    /// Read from the compiler, not `uname`, so a Rosetta-translated build reports the slice actually executing.
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

public extension DiagnosticsBundle {

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
    func padded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}

/// Allow-list vs withheld (summarised as a `…Configured` bool); a key in neither is dropped fail-closed and trips the `DiagnosticsTests` check.
public enum DiagnosticsRedaction {

    /// Non-identifying only: booleans, enum tokens, numeric limits, and paths — paths only because ``scrub(_:)`` rewrites home to `~`.
    public static let safeSettingsKeys: Set<String> = [
        "speedLimitEnabled", "defaultSaveDirectory",
        "theme", "language", "launchAtLogin", "launchMinimized", "menuBarExtraEnabled",
        "defaultFolderRule", "existingFileReaction", "clipboardMonitorEnabled",
        "hlsMaxHeight", "detailPanelPosition",
        "proxyMode", "proxyType", "proxyAllProtocols", "connectionTimeout",
        "retryCount", "retryInterval", "autoRetryEnabled", "autoRetryMaxAttempts",
        "cookieAuthEnabled",
        "aggregationEnabled", "aggregationIncludeExpensive", "aggregationAllowOutsideVPN",
        "aggregationStreamsPerAdapter", "aggregationStrategy", "aggregationPathDiversityProbe",
        "btMakeDefaultClient", "btAutoDeleteTorrent", "btWatchFolderEnabled",
        "btWatchFolderPath", "btWatchStartWithoutConfirmation", "btEncryptionMode",
        "btEnableDHT", "btEnablePeX", "btEnableLPD", "btEnableUTP",
        "notifyOnAdded", "notifyOnCompleted", "notifyOnFailed",
        "notifyOnlyWhenInactive", "notificationSound",
        "preventSleepWhileDownloading", "allowSleepIfResumable", "allowSleepWhileSeeding",
        "pauseBelowBatteryThreshold", "batteryThresholdPercent", "dontSeedOnBattery",
        "backupEnabled", "backupIntervalHours", "backupKeepCount",
        "antivirusEnabled", "antivirusScanner", "antivirusExecutablePath",
        "autoShutdownAction", "scheduleEnabled", "scheduleStartMinute",
        "scheduleEndMinute", "scheduleDays",
        "pauseOnExpensiveNetwork", "pauseOnConstrainedNetwork",
        "postDownloadExtractArchives", "postDownloadScriptEnabled", "postDownloadScriptPath",
        "autoRedownloadOnRemoteChange", "subtitleDownloadEnabled",
        "subtitleLanguages", "subtitleIncludeAutoGenerated", "ffmpegPath",
        "mediaConcurrency",
        // Remote access: the switches, never the credentials.
        "remoteAccessEnabled", "remotePort", "remoteAllowLAN", "remoteRequireAuth",
        "remoteReadOnly", "remoteSessionMinutes", "remoteTheme",
        // Portal hardening: booleans, numeric limits, a header name, and one path scrub() rewrites — none name a person.
        "remoteTLSEnabled", "remoteTLSIdentityPath",
        "remoteLoginMaxAttempts", "remoteLoginBackoffSeconds",
        "remoteTrustedHeaderAuthEnabled", "remoteTrustedHeaderName",
        // Audit log: switches, retention limits, and a path scrub() rewrites.
        "auditLogEnabled", "auditLogDirectory", "auditLogRetentionDays",
        "auditLogKeepFiles", "auditLogMaxFileMegabytes",
        "rssPollIntervalMinutes",
        "autoCheckUpdates",
    ]

    /// Never emitted verbatim: secrets, identities, network locations (a proxy or feed address names the employer), and free-form text.
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
        // A list of internal IPs/CIDRs is a network location, withheld for the same reason as `proxyHost`: it identifies the employer.
        "remoteTrustedProxies",
    ]

    /// The coverage test diffs this against the type's real encoded keys, so a field added without a privacy class fails the suite instead of leaking.
    public static var reviewedSettingsKeys: Set<String> {
        safeSettingsKeys.union(withheldSettingsKeys)
    }

    /// Home dirs → `~`, leftover `/Users/<name>` and `/home/<name>` → `<user>`, then the bare account name — skipped under 3 chars (false positives).
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

    /// Longest-first so `/Users/me/Library/Containers/app/Data` is matched before the plain `/Users/me` that prefixes it.
    private static var homeDirectoryCandidates: [String] {
        let paths = [NSHomeDirectory(), FileManager.default.homeDirectoryForCurrentUser.path]
        return Array(Set(paths)).sorted { $0.count > $1.count }
    }

    /// Allow-listed keys read out of the type's *own* `Codable` encoding (so it cannot drift) then scrubbed; withheld keys become "is this configured?" only.
    public static func sanitisedSettings(_ settings: AppSettings) -> [String: String] {
        var dump: [String: String] = [:]

        for (key, value) in encodedFields(of: settings) where safeSettingsKeys.contains(key) {
            dump[key] = scrub(value.displayText)
        }

        // Stand-ins for the withheld fields: booleans and counts only, never a length or a prefix, which would narrow a secret's search space.
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

/// Not `JSONSerialization`: it bridges JSON booleans to `NSNumber`, so `true` and `1` collapse and every flag prints as a digit.
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

    /// Nested objects collapse to `{…}`: an allow-listed key that becomes an object must be reviewed field by field, not dumped wholesale.
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
