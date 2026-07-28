import XCTest
@testable import GoelCore

/// Regression tests for the settings-validation / automation / app-lifecycle pass. Every defect was
/// an *absent* boundary; each test fails against pre-fix behaviour, several by crashing the process.
final class AppShellRemediationTests: XCTestCase {

    private let saveDir = NSTemporaryDirectory()

    // MARK: AppSettings.validated() — numeric boundaries

    func testSimultaneousDownloadsZeroBecomesOneNotUnlimited() {
        // `SchedulingPolicy`'s contract is "0 (or negative) means unlimited", so typing 0 into "Max
        // simultaneous downloads" gave the opposite. The policy is unchanged; 0 can't reach it now.
        var profile = TrafficProfile.medium
        profile.maxSimultaneousDownloads = 0
        XCTAssertEqual(profile.validated().maxSimultaneousDownloads, 1)

        profile.maxSimultaneousDownloads = -7
        XCTAssertEqual(profile.validated().maxSimultaneousDownloads, 1)

        profile.maxSimultaneousDownloads = Int.max
        XCTAssertEqual(profile.validated().maxSimultaneousDownloads, 100)
    }

    func testProfileLimitsAreClampedButZeroStillMeansUnlimitedBytes() {
        var profile = TrafficProfile.medium
        profile.maxDownloadBytesPerSec = 0            // unlimited — must survive
        profile.maxUploadBytesPerSec = -1
        profile.maxConnections = 0
        profile.maxConnectionsPerServer = 100_000
        profile.maxMetadataResolutions = -3
        profile.seedRatioLimit = .nan

        let v = profile.validated()
        XCTAssertEqual(v.maxDownloadBytesPerSec, 0)
        XCTAssertEqual(v.maxUploadBytesPerSec, 0)
        XCTAssertEqual(v.maxConnections, 1)
        XCTAssertEqual(v.maxConnectionsPerServer, 256)
        XCTAssertEqual(v.maxMetadataResolutions, 1)
        XCTAssertEqual(v.seedRatioLimit, 0)           // NaN has no clamp
    }

    func testSettingsBoundaryMatrix() {
        var s = AppSettings()
        s.hlsMaxHeight = -1
        s.proxyPort = 99_999
        s.connectionTimeout = 0
        s.retryCount = -4
        s.retryInterval = .infinity
        s.autoRetryMaxAttempts = 5_000
        s.aggregationStreamsPerAdapter = 0
        s.batteryThresholdPercent = 400
        s.backupIntervalHours = 0
        s.backupKeepCount = 0
        s.scheduleStartMinute = -30
        s.scheduleEndMinute = 5_000
        s.rssPollIntervalMinutes = 1
        s.remotePort = 0
        s.remoteSessionMinutes = 1
        s.remoteLoginMaxAttempts = 0
        s.remoteLoginBackoffSeconds = 0
        s.auditLogRetentionDays = -1
        s.auditLogKeepFiles = -1
        s.auditLogMaxFileMegabytes = 0

        let v = s.validated()
        XCTAssertEqual(v.hlsMaxHeight, 0)
        XCTAssertEqual(v.proxyPort, 65_535)
        XCTAssertEqual(v.connectionTimeout, 1)
        XCTAssertEqual(v.retryCount, 0)
        XCTAssertEqual(v.retryInterval, 5)            // non-finite → the default
        XCTAssertEqual(v.autoRetryMaxAttempts, 20)
        XCTAssertEqual(v.aggregationStreamsPerAdapter, 1)
        XCTAssertEqual(v.batteryThresholdPercent, 100)
        XCTAssertEqual(v.backupIntervalHours, 1)
        XCTAssertEqual(v.backupKeepCount, 1)
        XCTAssertEqual(v.scheduleStartMinute, 0)
        XCTAssertEqual(v.scheduleEndMinute, 1_439)
        XCTAssertEqual(v.rssPollIntervalMinutes, 5)
        XCTAssertEqual(v.remotePort, 1)
        XCTAssertEqual(v.remoteSessionMinutes, 5)
        XCTAssertEqual(v.remoteLoginMaxAttempts, 1)
        XCTAssertEqual(v.remoteLoginBackoffSeconds, 1)
        XCTAssertEqual(v.auditLogRetentionDays, 0)
        XCTAssertEqual(v.auditLogKeepFiles, 0)
        XCTAssertEqual(v.auditLogMaxFileMegabytes, 1)
    }

    func testDefaultsAreAlreadyValidSoNoInstallMoves() {
        // The clamp is only safe if every shipped default already sits inside its range — otherwise
        // the first launch after this change would silently rewrite the user's settings.
        let defaults = AppSettings()
        XCTAssertEqual(defaults, defaults.validated())
        for profile in TrafficProfile.defaults {
            XCTAssertEqual(profile, profile.validated())
        }
    }

    func testScheduleDaysAreFilteredDedupedAndNeverEmpty() {
        var s = AppSettings()
        s.scheduleDays = [7, 0, 3, 3, 9, -2, 1]
        XCTAssertEqual(s.validated().scheduleDays, [1, 3, 7])

        // A day list that matches nothing would hold the queue closed forever.
        s.scheduleDays = [0, 42]
        XCTAssertEqual(s.validated().scheduleDays, [1, 2, 3, 4, 5, 6, 7])
    }

    // MARK: AppSettings.validated() — string coercions

    func testUnsupportedLanguageIsRepairedRatherThanLeftBlank() {
        // The picker used to offer हिन्दी and 日本語, which ship no strings table. A value persisted
        // from that build must resolve to a listed language, or the control renders an empty trigger.
        var s = AppSettings()
        s.language = "हिन्दी"
        XCTAssertEqual(s.validated().language, "English")

        s.language = "German"                  // an alias L10n already knows
        XCTAssertEqual(s.validated().language, "Deutsch")

        s.language = "Deutsch"                 // a supported name survives verbatim
        XCTAssertEqual(s.validated().language, "Deutsch")

        for entry in L10n.supportedLanguages {
            var t = AppSettings()
            t.language = entry.name
            XCTAssertEqual(t.validated().language, entry.name)
        }
    }

    func testUnknownExistingFileReactionCoercesToRename() {
        var s = AppSettings()
        s.existingFileReaction = "skip"        // documented once, never implemented
        XCTAssertEqual(s.validated().existingFileReaction, "rename")

        s.existingFileReaction = "¯\\_(ツ)_/¯"
        XCTAssertEqual(s.validated().existingFileReaction, "rename")

        s.existingFileReaction = "overwrite"   // an explicit choice is honoured
        XCTAssertEqual(s.validated().existingFileReaction, "overwrite")
    }

    // MARK: Non-trapping arithmetic

    func testAuditConfigurationSurvivesAnAbsurdRotationSize() {
        // `megabytes * 1024 * 1024` TRAPS on Int overflow — a hard crash reachable from the Audit
        // Log pane's number field and from any imported backup. This test crashed before the clamp.
        var s = AppSettings()
        s.auditLogEnabled = true
        s.auditLogMaxFileMegabytes = Int.max
        let config = AuditLog.Configuration(settings: s)
        XCTAssertEqual(config.maxFileBytes, 1024 * 1024 * 1024)

        s.auditLogMaxFileMegabytes = 8
        XCTAssertEqual(AuditLog.Configuration(settings: s).maxFileBytes, 8 * 1024 * 1024)
    }

    func testSessionStoreSurvivesAnAbsurdSessionLength() async {
        // `max(5, minutes) * 60` traps the same way from the Web Access pane.
        let store = RemoteSessionStore()
        await store.configure(username: "admin", passwordHash: "", sessionMinutes: Int.max)
        await store.configure(username: "admin", passwordHash: "", sessionMinutes: Int.min)
    }

    func testImportedSettingsAreClampedBeforeTheSchedulingArithmetic() {
        // `UInt64(hours) * 3600 * 1e9` and the RSS equivalent trap too, and the import sanitiser
        // resets neither — a corrupt backup crashed on import. `validated()` is the boundary.
        var hostile = AppSettings()
        hostile.backupIntervalHours = Int.max
        hostile.rssPollIntervalMinutes = Int.max
        hostile.auditLogMaxFileMegabytes = Int.max
        hostile.remoteSessionMinutes = Int.max
        hostile.existingFileReaction = "skip"

        let safe = DownloadManager
            .sanitizedImportedSettings(hostile, current: AppSettings())
            .validated()
        XCTAssertEqual(safe.backupIntervalHours, 8_760)
        XCTAssertEqual(safe.rssPollIntervalMinutes, 10_080)
        XCTAssertEqual(safe.auditLogMaxFileMegabytes, 1024)
        XCTAssertEqual(safe.remoteSessionMinutes, 120)   // forced back by the sanitiser
        XCTAssertEqual(safe.existingFileReaction, "rename")

        // The arithmetic the clamps protect. These *trap* — they don't throw — so
        // the assertion is that the process is still here to evaluate them.
        XCTAssertEqual(UInt64(safe.backupIntervalHours) * 3600 * 1_000_000_000,
                       8_760 * 3600 * 1_000_000_000)
        XCTAssertEqual(UInt64(safe.rssPollIntervalMinutes) * 60 * 1_000_000_000,
                       10_080 * 60 * 1_000_000_000)
    }

    func testManagerValidatesSettingsHandedToIt() async {
        var s = AppSettings(defaultSaveDirectory: saveDir)
        s.profiles = [TrafficProfile(name: "Broken", maxDownloadBytesPerSec: -1,
                                     maxUploadBytesPerSec: 0, maxConnections: 0,
                                     maxConnectionsPerServer: 0, maxSimultaneousDownloads: 0,
                                     maxMetadataResolutions: 0, seedRatioLimit: -5,
                                     enableExtraConnections: false)]
        s.selectedProfileName = "Broken"
        s.existingFileReaction = "skip"

        let m = DownloadManager(httpEngine: FakeEngine(kind: .http),
                                torrentEngine: FakeEngine(kind: .torrent),
                                settings: s)
        let effective = await m.currentSettings
        XCTAssertEqual(effective.selectedProfile.maxSimultaneousDownloads, 1)
        XCTAssertEqual(effective.selectedProfile.maxConnections, 1)
        XCTAssertEqual(effective.selectedProfile.maxDownloadBytesPerSec, 0)
        XCTAssertEqual(effective.existingFileReaction, "rename")

        // …and again through the update funnel, which is what the remote API and
        // the daemon go through.
        var worse = effective
        worse.remotePort = -1
        await m.updateSettings(worse)
        let after = await m.currentSettings
        XCTAssertEqual(after.remotePort, 1)
    }

    // MARK: File-conflict policy fails closed

    func testUnknownConflictPolicyKeepsBothFilesInsteadOfOverwriting() throws {
        let dir = NSTemporaryDirectory() + "goel-conflict-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let existing = (dir as NSString).appendingPathComponent("payload.bin")
        try Data("original".utf8).write(to: URL(fileURLWithPath: existing))

        // "skip" was documented in AppSettings and never implemented; it — and any other
        // unrecognised value — used to fall through to keeping the name, truncating the user's file.
        for policy in ["skip", "", "RENAME", "junk"] {
            let resolved = DownloadManager.resolveName("payload.bin", in: dir, policy: policy)
            XCTAssertNotEqual(resolved, "payload.bin", "policy \"\(policy)\" targeted the existing file")
        }
        XCTAssertNotEqual(DownloadManager.resolveName("payload.bin", in: dir, policy: "rename"),
                          "payload.bin")
        // Only an explicit "overwrite" is allowed to reuse the name.
        XCTAssertEqual(DownloadManager.resolveName("payload.bin", in: dir, policy: "overwrite"),
                       "payload.bin")
        // A free name is untouched whatever the policy.
        XCTAssertEqual(DownloadManager.resolveName("fresh.bin", in: dir, policy: "skip"), "fresh.bin")
    }

    // MARK: Antivirus covers every file of a multi-file torrent

    private func multiFileTask(files: [TransferFile]) -> DownloadTask {
        DownloadTask(source: .magnet("magnet:?xt=urn:btih:\(String(repeating: "a", count: 40))"),
                     name: "Pack",
                     saveDirectory: saveDir,
                     status: .completed,
                     files: files)
    }

    func testScanTargetsExpandEveryWantedFileOfAMultiFileTorrent() {
        let task = multiFileTask(files: [
            TransferFile(id: 0, path: "a.bin", length: 10),
            TransferFile(id: 1, path: "nested/b.bin", length: 20),
            TransferFile(id: 2, path: "skipped.bin", length: 30, priority: .skip),
        ])
        let targets = DownloadManager.scanTargets(for: task)
        XCTAssertEqual(Set(targets), [
            (saveDir as NSString).appendingPathComponent("a.bin"),
            (saveDir as NSString).appendingPathComponent("nested/b.bin"),
        ])
        // The containing folder is emphatically NOT what gets scanned.
        XCTAssertFalse(targets.contains(task.savePath))
    }

    func testScanTargetsDropTraversingPathsAndFailClosedWhenNoneRemain() {
        let escaping = multiFileTask(files: [
            TransferFile(id: 0, path: "../../etc/passwd", length: 10),
            TransferFile(id: 1, path: "../elsewhere.bin", length: 20),
        ])
        // Empty, not "fall back to the save folder" — an empty list is a refusal.
        XCTAssertTrue(DownloadManager.scanTargets(for: escaping).isEmpty)

        let single = DownloadTask(source: .url(URL(string: "https://example.test/x.bin")!),
                                  name: "x.bin", saveDirectory: saveDir, status: .completed)
        XCTAssertEqual(DownloadManager.scanTargets(for: single), [single.savePath])
    }

    func testAntivirusScansEveryFileAndOneFailureFailsTheWholeTask() async {
        let scanner = FakeScanner(result: true)
        var settings = AppSettings(defaultSaveDirectory: saveDir)
        settings.antivirusEnabled = true
        settings.antivirusExecutablePath = "/usr/bin/clamscan"
        settings.antivirusArgumentTemplate = "--quiet %path%"
        let m = DownloadManager(httpEngine: FakeEngine(kind: .http),
                                torrentEngine: FakeEngine(kind: .torrent),
                                settings: settings, scanner: scanner)

        let task = multiFileTask(files: [
            TransferFile(id: 0, path: "a.bin", length: 10),
            TransferFile(id: 1, path: "b.bin", length: 20),
        ])
        await m.onDownloadCompleted(task)

        let scanned = await waitUntil { scanner.calls.count == 2 }
        XCTAssertTrue(scanned, "every wanted file must be screened, not just the folder")
        XCTAssertEqual(Set(scanner.scannedPaths), [
            (saveDir as NSString).appendingPathComponent("a.bin"),
            (saveDir as NSString).appendingPathComponent("b.bin"),
        ])

        // A refusing scanner stops at the first failure rather than scanning on.
        let refusing = FakeScanner(result: false)
        let m2 = DownloadManager(httpEngine: FakeEngine(kind: .http),
                                 torrentEngine: FakeEngine(kind: .torrent),
                                 settings: settings, scanner: refusing)
        await m2.onDownloadCompleted(task)
        _ = await waitUntil { refusing.calls.count == 1 }
        let extra = await waitUntil(timeout: 0.5) { refusing.calls.count > 1 }
        XCTAssertFalse(extra, "the first failure must win — no file is scanned after it")
    }

    func testMultiFileTaskWithNoScreenableFileIsFlaggedNotScanned() async {
        let scanner = FakeScanner(result: true)
        var settings = AppSettings(defaultSaveDirectory: saveDir)
        settings.antivirusEnabled = true
        settings.antivirusExecutablePath = "/usr/bin/clamscan"
        let m = DownloadManager(httpEngine: FakeEngine(kind: .http),
                                torrentEngine: FakeEngine(kind: .torrent),
                                settings: settings, scanner: scanner)

        let escaping = multiFileTask(files: [
            TransferFile(id: 0, path: "../a.bin", length: 10),
            TransferFile(id: 1, path: "../../b.bin", length: 20),
        ])
        await m.onDownloadCompleted(escaping)

        // Fail closed: nothing scanned, and certainly not the containing folder.
        let scannedAnyway = await waitUntil(timeout: 0.5) { !scanner.calls.isEmpty }
        XCTAssertFalse(scannedAnyway)
    }

    // MARK: Post-download extraction

    func testExtractableArchiveKindNamesOnlyWhatCanActuallyBeUnpacked() {
        XCTAssertEqual(DownloadManager.extractableArchiveKind(for: "/tmp/pack.zip"), "zip")
        XCTAssertEqual(DownloadManager.extractableArchiveKind(for: "/tmp/PACK.ZIP"), "zip")
        // Everything else is a *stated* skip rather than a silent no-op.
        for path in ["/tmp/pack.rar", "/tmp/pack.7z", "/tmp/pack.tar.gz", "/tmp/pack", "/tmp/.zipper"] {
            XCTAssertNil(DownloadManager.extractableArchiveKind(for: path), path)
        }
    }

    // MARK: Battery-threshold pause

    private func batterySettings(threshold: Int, enabled: Bool = true) -> AppSettings {
        var s = AppSettings()
        s.pauseBelowBatteryThreshold = enabled
        s.batteryThresholdPercent = threshold
        return s
    }

    private func phase(_ id: UUID, downloading: Bool = false) -> AutomationCore.TaskPhase {
        .init(id: id, downloadingPhase: downloading, paused: !downloading,
              terminal: false, scheduledAt: nil, dedupKey: id.uuidString)
    }

    /// 2026-07-08 is a Wednesday; the tests below only need a fixed instant so a
    /// schedule window's open/closed state never depends on when they run.
    private var fixedNoon: Date {
        var c = DateComponents()
        c.year = 2026; c.month = 7; c.day = 8; c.hour = 12
        return Calendar.current.date(from: c)!
    }

    private func powerSnapshot(_ settings: AppSettings, tasks: [AutomationCore.TaskPhase],
                               onBattery: Bool, percent: Int?,
                               memory: AutomationCore.Memory = .init()) -> AutomationCore.Snapshot {
        .init(now: fixedNoon, calendar: .current, settings: settings, tasks: tasks,
              networkExpensive: false, networkConstrained: false,
              onBattery: onBattery, batteryPercent: percent, memory: memory)
    }

    func testLowBatteryPausesActiveDownloadsAndRecoveryResumesExactlyThose() {
        let a = UUID(), b = UUID(), idle = UUID()
        let settings = batterySettings(threshold: 20)
        let tasks = [phase(a, downloading: true), phase(b, downloading: true), phase(idle)]

        let low = AutomationCore.decide(
            powerSnapshot(settings, tasks: tasks, onBattery: true, percent: 12))
        XCTAssertEqual(Set(low.actions), [.pause(a, .power), .pause(b, .power)])
        XCTAssertTrue(low.memory.powerPaused)
        XCTAssertEqual(low.memory.powerPausedIDs, [a, b])

        // Plugging back in resumes exactly the set the policy paused.
        let recovered = AutomationCore.decide(
            powerSnapshot(settings, tasks: tasks, onBattery: false, percent: 12,
                          memory: low.memory))
        XCTAssertEqual(Set(recovered.actions), [.resume(a), .resume(b)])
        XCTAssertFalse(recovered.memory.powerPaused)
        XCTAssertTrue(recovered.memory.powerPausedIDs.isEmpty)
    }

    func testBatteryPolicyIsInertUntilItActuallyApplies() {
        let a = UUID()
        let tasks = [phase(a, downloading: true)]

        // Off: the flag is what arms the policy, not the percentage.
        let disabled = AutomationCore.decide(
            powerSnapshot(batterySettings(threshold: 20, enabled: false),
                          tasks: tasks, onBattery: true, percent: 3))
        XCTAssertTrue(disabled.actions.isEmpty)

        // On AC: charge level is irrelevant.
        let onAC = AutomationCore.decide(
            powerSnapshot(batterySettings(threshold: 20), tasks: tasks,
                          onBattery: false, percent: 3))
        XCTAssertTrue(onAC.actions.isEmpty)

        // Above the threshold.
        let healthy = AutomationCore.decide(
            powerSnapshot(batterySettings(threshold: 20), tasks: tasks,
                          onBattery: true, percent: 21))
        XCTAssertTrue(healthy.actions.isEmpty)

        // Exactly at it — "below the threshold" includes the threshold itself.
        let atThreshold = AutomationCore.decide(
            powerSnapshot(batterySettings(threshold: 20), tasks: tasks,
                          onBattery: true, percent: 20))
        XCTAssertEqual(atThreshold.actions, [.pause(a, .power)])

        // No readable level (a desktop) reads as full, never as flat.
        let noBattery = AutomationCore.decide(
            powerSnapshot(batterySettings(threshold: 20), tasks: tasks,
                          onBattery: true, percent: nil))
        XCTAssertTrue(noBattery.actions.isEmpty)
    }

    func testWindowOwnsATaskTheBatteryPolicyWouldOtherwiseClaim() {
        // Single-owner ordering: window > network > power. A task paused by the closing window this
        // tick must not also hit the battery ledger, or reopening and recharging both resume it.
        let a = UUID()
        var settings = batterySettings(threshold: 90)
        settings.scheduleEnabled = true
        settings.scheduleStartMinute = 22 * 60  // 22:00–07:00: closed at the fixed noon
        settings.scheduleEndMinute = 7 * 60
        settings.scheduleDays = [1, 2, 3, 4, 5, 6, 7]

        var closed = AutomationCore.Memory()
        closed.windowOpen = true
        let d = AutomationCore.decide(
            powerSnapshot(settings, tasks: [phase(a, downloading: true)],
                          onBattery: true, percent: 5, memory: closed))
        XCTAssertEqual(d.actions, [.pause(a, .window)])
        XCTAssertEqual(d.memory.windowPausedIDs, [a])
        XCTAssertTrue(d.memory.powerPausedIDs.isEmpty)
        XCTAssertFalse(d.memory.powerPaused)
    }

    // MARK: Helpers

    /// Poll a predicate until it holds or the timeout fires.
    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ predicate: @escaping () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await predicate()
    }
}
