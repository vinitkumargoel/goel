import XCTest
@testable import GoelCore

/// Privacy tests enforcing the shipped "no telemetry" guarantee: plant secrets in every
/// credential-bearing ``AppSettings`` field and assert none survives into the diagnostics bundle.
final class DiagnosticsTests: XCTestCase {

    // MARK: Fixtures

    /// Unique, unmistakable needles chosen so a substring search can't match by accident; none is a
    /// settings *key* name, since key names legitimately appear in the report's "withheld" list.
    private enum Secret {
        static let token          = "TOKEN-b7f3d9e1c4a24f8e9d0c1b2a3e4f5061"
        static let passwordHash   = "v2$SALT99CAFEBABE$HASH99DEADBEEF"
        static let remoteUser     = "quartermaster-9911"
        static let proxyHost      = "egress.internal.acmecorp.invalid"
        static let proxyPort      = 31287
        static let userAgent      = "GoelDownloader/1.0 (bearer UA99SECRET99)"
        static let avArguments    = "--licence AVKEY99ZULU %path%"
        static let scriptArgs     = "--api-key SCRIPTKEY99YANKEE %path%"
        static let profileLabel   = "Fibre at 99 Tango Road"
        static let scheduleLabel  = "Overnight for 99 Whiskey Ltd"
        static let rssFeed        = "https://tracker.invalid/rss?passkey=RSSPASS99XRAY"
        static let updateFeed     = "https://updates.invalid/appcast.xml?tenant=TENANT99VICTOR"
        static let adapterID      = "utun99secret"

        /// Everything that must never appear in any rendering of the bundle.
        static let all: [String] = [
            token, passwordHash, remoteUser, proxyHost, String(proxyPort), userAgent,
            avArguments, scriptArgs, profileLabel, scheduleLabel, rssFeed, updateFeed,
            adapterID,
        ]
    }

    /// An `AppSettings` with a planted secret in every withheld field.
    private func settingsFullOfSecrets() -> AppSettings {
        var settings = AppSettings()
        settings.profiles = [
            TrafficProfile(
                name: Secret.profileLabel,
                maxDownloadBytesPerSec: 12_000_000,
                maxUploadBytesPerSec: 3_000_000,
                maxConnections: 64,
                maxConnectionsPerServer: 8,
                maxSimultaneousDownloads: 5,
                maxMetadataResolutions: 3,
                seedRatioLimit: 1.5,
                enableExtraConnections: true
            ),
        ]
        settings.selectedProfileName = Secret.profileLabel
        settings.proxyMode = "manual"
        settings.proxyHost = Secret.proxyHost
        settings.proxyPort = Secret.proxyPort
        settings.userAgent = Secret.userAgent
        settings.aggregationAdapterIds = [Secret.adapterID]
        settings.antivirusArgumentTemplate = Secret.avArguments
        settings.scheduleProfileName = Secret.scheduleLabel
        settings.postDownloadScriptArgs = Secret.scriptArgs
        settings.remoteToken = Secret.token
        settings.remoteUsername = Secret.remoteUser
        settings.remotePasswordHash = Secret.passwordHash
        settings.rssFeeds = [RSSFeed(url: Secret.rssFeed, titlePattern: "1080p")]
        settings.updateFeedURL = Secret.updateFeed
        return settings
    }

    /// Every textual form the bundle can take, so a leak in one renderer cannot
    /// hide behind a clean one.
    private func allRenderings(of bundle: DiagnosticsBundle) throws -> [(label: String, text: String)] {
        let json = try XCTUnwrap(String(data: bundle.jsonData(), encoding: .utf8))
        let settingsText = bundle.settings
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: "\n")
        return [
            ("plainText", bundle.plainText),
            ("jsonData", json),
            ("settings", settingsText),
        ]
    }

    // MARK: The core requirement — no secret survives

    func testBundleContainsNoneOfThePlantedSecrets() throws {
        let bundle = DiagnosticsBundle.make(settings: settingsFullOfSecrets(), tasks: [])

        for (label, text) in try allRenderings(of: bundle) {
            for secret in Secret.all {
                XCTAssertFalse(
                    text.contains(secret),
                    "\(label) leaked a secret: \(secret) — the diagnostics bundle is user-sendable, "
                    + "so every field must be allow-listed in DiagnosticsRedaction.safeSettingsKeys"
                )
            }
        }
    }

    func testWithheldFieldsAreReplacedByBooleanFactsOnly() {
        let dump = DiagnosticsRedaction.sanitisedSettings(settingsFullOfSecrets())

        // The fact of configuration is diagnostically useful; the value is not.
        XCTAssertEqual(dump["remoteTokenConfigured"], "true")
        XCTAssertEqual(dump["remotePasswordConfigured"], "true")
        XCTAssertEqual(dump["remoteUsernameConfigured"], "true")
        XCTAssertEqual(dump["proxyConfigured"], "true")
        XCTAssertEqual(dump["userAgentIsCustom"], "true")
        XCTAssertEqual(dump["antivirusArgumentsCustomised"], "true")
        XCTAssertEqual(dump["postDownloadScriptArgsCustomised"], "true")
        XCTAssertEqual(dump["scheduleProfileConfigured"], "true")
        XCTAssertEqual(dump["updateFeedIsCustom"], "true")
        XCTAssertEqual(dump["rssFeedCount"], "1")
        XCTAssertEqual(dump["rssFeedEnabledCount"], "1")
        XCTAssertEqual(dump["aggregationAdapterCount"], "1")

        // …and no key at all carries the withheld value itself.
        for key in DiagnosticsRedaction.withheldSettingsKeys {
            XCTAssertNil(dump[key], "\(key) is withheld and must not appear as a key in the dump")
        }
    }

    func testDefaultSettingsReportNothingConfigured() {
        let dump = DiagnosticsRedaction.sanitisedSettings(AppSettings())
        XCTAssertEqual(dump["remoteTokenConfigured"], "false")
        XCTAssertEqual(dump["remotePasswordConfigured"], "false")
        XCTAssertEqual(dump["proxyConfigured"], "false")
        XCTAssertEqual(dump["userAgentIsCustom"], "false")
        XCTAssertEqual(dump["updateFeedIsCustom"], "false")
        XCTAssertEqual(dump["rssFeedCount"], "0")
    }

    // MARK: The guard against future leaks

    /// Fails when an `AppSettings` field is added without anyone deciding it is safe for a support
    /// bundle. Without it the allow-list rots and a later `sftpPassphrase`/`apiKey` leaks silently.
    func testEverySettingsFieldHasBeenClassified() {
        let actual = DiagnosticsRedaction.encodedSettingsKeys()
        let reviewed = DiagnosticsRedaction.reviewedSettingsKeys

        let unclassified = actual.subtracting(reviewed).sorted()
        XCTAssertTrue(
            unclassified.isEmpty,
            "New AppSettings field(s) \(unclassified) are not classified. Add each one to either "
            + "DiagnosticsRedaction.safeSettingsKeys (non-identifying) or .withheldSettingsKeys "
            + "(secret / credential / hostname / URL / free-form text)."
        )

        let stale = reviewed.subtracting(actual).sorted()
        XCTAssertTrue(
            stale.isEmpty,
            "DiagnosticsRedaction lists \(stale), which no longer exist on AppSettings — remove them "
            + "so the coverage assertion keeps meaning something."
        )
    }

    /// A key whose *name* looks sensitive must never be in the allow-list, even
    /// if today's value happens to be harmless.
    func testNoSensitiveLookingKeyIsAllowListed() {
        let sensitiveFragments = [
            "token", "password", "passwd", "passphrase", "secret", "credential",
            "apikey", "api_key", "privatekey", "username", "hash", "bearer", "auth_",
        ]

        for key in DiagnosticsRedaction.safeSettingsKeys {
            let lowered = key.lowercased()
            for fragment in sensitiveFragments {
                XCTAssertFalse(
                    lowered.contains(fragment),
                    "\(key) matches the sensitive pattern '\(fragment)' but is allow-listed for the "
                    + "diagnostics bundle — move it to withheldSettingsKeys and summarise it instead."
                )
            }
        }
    }

    /// The fields the brief names explicitly must be withheld, permanently.
    func testMandatorySecretsAreWithheld() {
        for key in ["remoteToken", "remotePasswordHash", "remoteUsername", "proxyHost", "proxyPort"] {
            XCTAssertTrue(
                DiagnosticsRedaction.withheldSettingsKeys.contains(key),
                "\(key) must never be emitted in a support bundle"
            )
            XCTAssertFalse(DiagnosticsRedaction.safeSettingsKeys.contains(key))
        }
    }

    /// Any emitted key that *reads* as sensitive (the derived stand-ins do:
    /// `remoteTokenConfigured`) must carry a boolean or a count, never a payload.
    func testDerivedStandInsCarryNoPayload() {
        let dump = DiagnosticsRedaction.sanitisedSettings(settingsFullOfSecrets())
        let sensitiveFragments = ["token", "password", "username", "proxy"]

        for (key, value) in dump {
            let lowered = key.lowercased()
            guard sensitiveFragments.contains(where: { lowered.contains($0) }) else { continue }
            let isBooleanOrCount = value == "true" || value == "false" || Int(value) != nil
                || DiagnosticsRedaction.safeSettingsKeys.contains(key)
            XCTAssertTrue(
                isBooleanOrCount,
                "\(key)=\(value) reads as sensitive but carries free text rather than a fact"
            )
        }
    }

    // MARK: Path scrubbing

    func testHomeDirectoryPrefixBecomesTilde() {
        var settings = AppSettings()
        settings.defaultSaveDirectory = NSHomeDirectory() + "/Downloads/Kingfisher"

        let dump = DiagnosticsRedaction.sanitisedSettings(settings)
        XCTAssertEqual(dump["defaultSaveDirectory"], "~/Downloads/Kingfisher")
        XCTAssertFalse(dump["defaultSaveDirectory"]?.contains(NSHomeDirectory()) ?? true)
    }

    func testAnotherAccountsHomePathIsGenericised() {
        var settings = AppSettings()
        settings.btWatchFolderPath = "/Users/j.doe-contractor/Torrents/inbox"
        settings.postDownloadScriptPath = "/home/buildbot/bin/post.sh"

        let dump = DiagnosticsRedaction.sanitisedSettings(settings)
        XCTAssertEqual(dump["btWatchFolderPath"], "/Users/<user>/Torrents/inbox")
        XCTAssertEqual(dump["postDownloadScriptPath"], "/home/<user>/bin/post.sh")
    }

    func testScrubLeavesNonHomePathsIntact() {
        XCTAssertEqual(DiagnosticsRedaction.scrub("/Volumes/Archive/media"), "/Volumes/Archive/media")
        XCTAssertEqual(DiagnosticsRedaction.scrub("/opt/homebrew/bin/ffmpeg"), "/opt/homebrew/bin/ffmpeg")
        XCTAssertEqual(DiagnosticsRedaction.scrub(""), "")
    }

    func testScrubRemovesTheShortAccountNameOutsidePathsToo() throws {
        let account = NSUserName()
        try XCTSkipIf(account.count < 3, "no meaningful account name in this environment")

        let scrubbed = DiagnosticsRedaction.scrub("host \(account)-mbp reported an error")
        XCTAssertFalse(scrubbed.contains(account),
                       "the account short name identifies the user and must not survive scrubbing")
    }

    // MARK: Task and engine facts (counts only — never identities)

    private func sampleTasks() -> [DownloadTask] {
        [
            DownloadTask(source: .url(URL(string: "https://cdn.invalid/PAYROLL99ALPHA.zip")!),
                         name: "PAYROLL99ALPHA.zip",
                         saveDirectory: "/Volumes/Vault/PROJECT99BRAVO",
                         status: .downloading),
            DownloadTask(source: .url(URL(string: "https://cdn.invalid/b.iso")!),
                         name: "b.iso", saveDirectory: "/tmp", status: .queued),
            DownloadTask(source: .magnet("magnet:?xt=urn:btih:aaaa"),
                         name: "c", saveDirectory: "/tmp", status: .seeding),
            DownloadTask(source: .url(URL(string: "sftp://host.invalid/d")!),
                         name: "d", saveDirectory: "/tmp", status: .failed(.httpStatus(404))),
            DownloadTask(source: .url(URL(string: "sftp://host.invalid/e")!),
                         name: "e", saveDirectory: "/tmp",
                         status: .failed(.network("could not reach https://cdn.invalid/PAYROLL99ALPHA.zip"))),
        ]
    }

    func testTaskCountsAreGroupedByStatus() {
        let bundle = DiagnosticsBundle.make(settings: AppSettings(), tasks: sampleTasks())
        XCTAssertEqual(bundle.totalTaskCount, 5)
        XCTAssertEqual(bundle.taskCountsByStatus["downloading"], 1)
        XCTAssertEqual(bundle.taskCountsByStatus["queued"], 1)
        XCTAssertEqual(bundle.taskCountsByStatus["seeding"], 1)
        XCTAssertEqual(bundle.taskCountsByStatus["failed"], 2)
        XCTAssertNil(bundle.taskCountsByStatus["completed"], "absent states are omitted, not zeroed")
    }

    func testFailureReasonsUseCaseNamesNotErrorMessages() throws {
        let bundle = DiagnosticsBundle.make(settings: AppSettings(), tasks: sampleTasks())
        XCTAssertEqual(bundle.failureCountsByStatus["http-404"], 1)
        XCTAssertEqual(bundle.failureCountsByStatus["network"], 1)

        // `DownloadError.network(_)` embeds the failing URL in its message; the
        // bundle must report only the case name.
        for (_, text) in try allRenderings(of: bundle) {
            XCTAssertFalse(text.contains("PAYROLL99ALPHA"))
            XCTAssertFalse(text.contains("cdn.invalid"))
        }
    }

    func testEngineStatesCoverEveryKindAndReportLiveness() {
        let bundle = DiagnosticsBundle.make(
            settings: AppSettings(),
            tasks: sampleTasks(),
            runningEngineKinds: [.http, .torrent]
        )
        XCTAssertEqual(bundle.engineStates.count, DownloadKind.allCases.count)

        let byKind = Dictionary(uniqueKeysWithValues: bundle.engineStates.map { ($0.kind, $0) })
        XCTAssertEqual(byKind["http"]?.isRunning, true)
        XCTAssertEqual(byKind["http"]?.totalTaskCount, 2)
        XCTAssertEqual(byKind["http"]?.activeTaskCount, 1)
        XCTAssertEqual(byKind["torrent"]?.activeTaskCount, 1, "seeding counts as active")
        XCTAssertEqual(byKind["sftp"]?.isRunning, false)
        XCTAssertEqual(byKind["sftp"]?.totalTaskCount, 2)
        XCTAssertEqual(byKind["sftp"]?.activeTaskCount, 0)
        XCTAssertEqual(byKind["hls"]?.totalTaskCount, 0)
    }

    func testBundleNeverCarriesTaskNamesURLsOrSavePaths() throws {
        let bundle = DiagnosticsBundle.make(settings: AppSettings(), tasks: sampleTasks())
        for (label, text) in try allRenderings(of: bundle) {
            XCTAssertFalse(text.contains("PAYROLL99ALPHA"), "\(label) leaked a task name")
            XCTAssertFalse(text.contains("PROJECT99BRAVO"), "\(label) leaked a save path")
            XCTAssertFalse(text.contains("magnet:"), "\(label) leaked a magnet link")
            XCTAssertFalse(text.contains("host.invalid"), "\(label) leaked a remote host")
        }
    }

    // MARK: Shape

    func testBundleRoundTripsThroughJSON() throws {
        let original = DiagnosticsBundle.make(
            settings: settingsFullOfSecrets(),
            tasks: sampleTasks(),
            runningEngineKinds: [.http],
            appVersion: "1.4.2",
            buildNumber: "412",
            systemVersion: "macOS 14.5.0",
            architecture: "arm64",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(DiagnosticsBundle.self, from: original.jsonData())
        XCTAssertEqual(restored, original)
    }

    func testPlainTextIsSelfDescribingAboutWhereItHasBeen() {
        let text = DiagnosticsBundle.make(settings: AppSettings(), tasks: []).plainText
        XCTAssertTrue(text.contains("has not been sent anywhere"),
                      "the report states the no-telemetry guarantee to the user who is about to send it")
        XCTAssertTrue(text.contains("Withheld"))
    }

    func testHostFactsAreAlwaysPopulated() {
        let bundle = DiagnosticsBundle.make(settings: AppSettings(), tasks: [])
        XCTAssertFalse(bundle.appVersion.isEmpty)
        XCTAssertFalse(bundle.buildNumber.isEmpty)
        XCTAssertFalse(bundle.systemVersion.isEmpty)
        XCTAssertTrue(["arm64", "x86_64", "unknown"].contains(bundle.architecture))
    }

    // MARK: GoelLog

    func testCategoriesMatchTheArchitecture() {
        XCTAssertEqual(
            Set(GoelLog.Category.allCases.map(\.rawValue)),
            ["engine.http", "engine.torrent", "engine.sftp", "engine.ftp", "engine.hls",
             "scheduler", "persistence", "remote", "app"]
        )
        for kind in DownloadKind.allCases {
            XCTAssertTrue(GoelLog.engine(kind).category.rawValue.hasPrefix("engine."))
        }
    }

    func testIdentifyingFieldsAreClassifiedPrivate() throws {
        let url = try XCTUnwrap(URL(string: "https://cdn.invalid/file.zip?sig=SIG99"))
        XCTAssertTrue(GoelLogField.url(url).isPrivate)
        XCTAssertTrue(GoelLogField.locator("magnet:?xt=urn:btih:abc").isPrivate)
        XCTAssertTrue(GoelLogField.path("/Users/x/Downloads").isPrivate)
        XCTAssertTrue(GoelLogField.host("sftp.invalid:22").isPrivate)
        XCTAssertTrue(GoelLogField.user("admin").isPrivate)
        XCTAssertTrue(GoelLogField.name("Holiday 2024.mkv").isPrivate)
        XCTAssertTrue(GoelLogField.detail("server said no").isPrivate)
    }

    func testBehaviouralFieldsAreClassifiedPublic() {
        XCTAssertFalse(GoelLogField.bytes(1024).isPrivate)
        XCTAssertFalse(GoelLogField.count(4, label: "segments").isPrivate)
        XCTAssertFalse(GoelLogField.duration(1.5).isPrivate)
        XCTAssertFalse(GoelLogField.speed(2048).isPrivate)
        XCTAssertFalse(GoelLogField.state("downloading").isPrivate)
        XCTAssertFalse(GoelLogField.code(206).isPrivate)
        XCTAssertFalse(GoelLogField.flag(true, label: "resumable").isPrivate)
        XCTAssertFalse(GoelLogField.kind(.torrent).isPrivate)
    }

    /// `DownloadError.message` embeds the failing URL, so the log's error field
    /// must expose the case name only.
    func testErrorKindFieldDropsTheErrorMessage() {
        let error = DownloadError.network("could not reach https://cdn.invalid/x?token=TOK99")
        let field = GoelLogField.errorKind(error)
        XCTAssertEqual(field.value, "network")
        XCTAssertFalse(field.isPrivate)
        XCTAssertFalse(field.value.contains("TOK99"))
        XCTAssertEqual(GoelLogField.errorKind(.httpStatus(503)).value, "http-503")
    }

    func testRenderedLineRedactsPrivateFieldsByDefault() throws {
        let url = try XCTUnwrap(URL(string: "https://cdn.invalid/private-file.zip?sig=SIG99"))
        let line = GoelLog.renderLine(
            level: .error,
            category: .engineHTTP,
            message: "Transfer failed",
            fields: [.code(403), .bytes(4096), .url(url)],
            revealPrivate: false
        )
        XCTAssertTrue(line.contains("[engine.http]"))
        XCTAssertTrue(line.contains("Transfer failed"))
        XCTAssertTrue(line.contains("code=403"))
        XCTAssertTrue(line.contains("bytes=4096"))
        XCTAssertTrue(line.contains("<private>"))
        XCTAssertFalse(line.contains("cdn.invalid"))
        XCTAssertFalse(line.contains("SIG99"))
    }

    func testRenderedLineRevealsPrivateFieldsOnlyWhenAsked() throws {
        let url = try XCTUnwrap(URL(string: "https://cdn.invalid/private-file.zip"))
        let line = GoelLog.renderLine(
            level: .debug, category: .remote, message: "Probe",
            fields: [.url(url)], revealPrivate: true
        )
        XCTAssertTrue(line.contains("cdn.invalid"))
        XCTAssertFalse(line.contains("<private>"))
    }

    func testRenderedLineOmitsTheSeparatorWhenThereIsNothingPrivate() {
        let line = GoelLog.renderLine(
            level: .notice, category: .scheduler, message: "Queue drained",
            fields: [.count(0, label: "remaining")], revealPrivate: false
        )
        XCTAssertFalse(line.contains("<private>"))
        XCTAssertFalse(line.contains("|"))
        XCTAssertTrue(line.contains("remaining=0"))
    }

    func testLevelOrderingAndParsing() {
        XCTAssertTrue(GoelLogLevel.debug < GoelLogLevel.fault)
        XCTAssertEqual(GoelLogLevel.named("ERROR"), .error)
        XCTAssertEqual(GoelLogLevel.named(" default "), .notice)
        XCTAssertNil(GoelLogLevel.named("chatty"))
    }

    /// Smoke test only: the emit path must not trap on any level or on an empty
    /// field list. What the sink *does* with the line is the platform's business.
    func testEmittingEveryLevelIsSafe() {
        for level in GoelLogLevel.allCases {
            GoelLog.app.log(level, "Diagnostics self-test", fields: [])
            GoelLog.app.log(level, "Diagnostics self-test", fields: [.state("ok"), .user("tester")])
        }
    }
}
