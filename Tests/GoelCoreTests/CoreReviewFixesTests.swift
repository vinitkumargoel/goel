import XCTest
@testable import GoelCore

/// Records `remove`'s `deleteData` flag, which ``RecordingEngine`` drops.
final class DeleteFlagEngine: DownloadEngine, @unchecked Sendable {
    let kind: DownloadKind
    private let lock = NSLock()
    private var _removals: [(UUID, Bool)] = []
    private var _added: [UUID] = []

    init(kind: DownloadKind) { self.kind = kind }

    func add(_ task: DownloadTask) async { lock.withLock { _added.append(task.id) } }
    func pause(_ id: DownloadTask.ID) async {}
    func resume(_ id: DownloadTask.ID) async {}
    func remove(_ id: DownloadTask.ID, deleteData: Bool) async { lock.withLock { _removals.append((id, deleteData)) } }
    func applyLimits(_ profile: TrafficProfile) async {}
    func events(for id: DownloadTask.ID) -> AsyncStream<EngineEvent> { AsyncStream { _ in } }

    var removals: [(UUID, Bool)] { lock.withLock { _removals } }
    var added: [UUID] { lock.withLock { _added } }
}

final class FakeCredentialStore: CredentialManaging, @unchecked Sendable {
    private let lock = NSLock()
    private var logins: [String: (String, String)] = [:]
    var failWrites = false

    func credential(forHost host: String) -> (username: String, password: String)? {
        lock.withLock { logins[host].map { (username: $0.0, password: $0.1) } }
    }
    func setCredential(username: String, password: String, host: String) -> Bool {
        guard !failWrites else { return false }
        lock.withLock { logins[host] = (username, password) }
        return true
    }
    func removeCredential(host: String) -> Bool { lock.withLock { logins[host] = nil }; return true }
    func allCredentials() -> [HostCredential] {
        lock.withLock { logins.map { HostCredential(host: $0.key, username: $0.value.0) } }
    }
}

extension DownloadManager {
    func forceSettingsLoadFailedForTesting() { settingsLoadFailed = true }
    func isEngineStartedForTesting(_ id: UUID) -> Bool { engineStarted.contains(id) }
    /// `restore()` sweeps payloads after publishing; tests that assert on its result wait for it.
    func settleInitialReconcile() async { await initialReconcile?.value }
}

final class CoreReviewFixesTests: XCTestCase {

    private var tempDirs: [String] = []
    private var restoreTrash: (() -> Void)?

    override func setUp() {
        super.setUp()
        restoreTrash = TestTrash.install()
    }

    override func tearDownWithError() throws {
        restoreTrash?()
        for dir in tempDirs {
            _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir)
            try? FileManager.default.removeItem(atPath: dir)
        }
        tempDirs.removeAll()
    }

    private func makeTempDir() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goel-corefix-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    @discardableResult
    private func waitUntil(timeout: TimeInterval = 5, _ predicate: @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await predicate()
    }

    private func url(_ s: String) -> DownloadSource { .url(URL(string: s)!) }

    private func touch(_ path: String, _ text: String = "x") {
        FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
    }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    private func manager(http: any DownloadEngine = RecordingEngine(kind: .http),
                         torrent: any DownloadEngine = RecordingEngine(kind: .torrent),
                         ftp: (any DownloadEngine)? = nil,
                         settings: AppSettings = AppSettings(),
                         store: PersistenceStore? = nil,
                         scanner: any FileScanning = FakeScanner(),
                         credentials: any CredentialManaging = FakeCredentialStore()) -> DownloadManager {
        DownloadManager(httpEngine: http, torrentEngine: torrent, ftpEngine: ftp,
                        settings: settings, store: store, scanner: scanner, credentials: credentials)
    }

    // MARK: 1 — removal only touches what is the download's

    func testRemovingAnUnfinishedHTTPDownloadKeepsTheUsersFileAtTheFinalPath() async {
        let dir = makeTempDir()
        let m = manager()
        let task = await m.add(source: url("https://e.test/report.pdf"), saveDirectory: dir,
                               startPaused: true, suggestedName: "report.pdf")
        touch(task.savePath, "the user's own report")
        touch(task.savePath + ".goelpart")

        let outcome = await m.removeAndReport(task.id, deleteData: true)
        XCTAssertEqual(outcome, .deleted, "only the partial was ours, and partials are unlinked")
        XCTAssertTrue(exists(task.savePath), "overwrite policy replaces it only on success — never on remove")
        XCTAssertFalse(exists(task.savePath + ".goelpart"))
        let notices = await m.takeNotices()
        XCTAssertTrue(notices.isEmpty)
    }

    func testRemovingACompletedDownloadMovesItToTheTrash() async throws {
        let dir = makeTempDir()
        let path = (dir as NSString).appendingPathComponent("done.bin")
        touch(path)
        let store = try PersistenceStore()
        let done = DownloadTask(source: url("https://e.test/done.bin"), name: "done.bin",
                                saveDirectory: dir, status: .completed, completedAt: Date())
        try store.saveTask(done)
        #if os(macOS)
        let trashed = LockedBox<[String]>([])
        let previous = RemoteTransferPrep.trashItem
        RemoteTransferPrep.trashItem = { url in
            trashed.mutate { $0.append(url.path) }
            try FileManager.default.removeItem(at: url)
        }
        defer { RemoteTransferPrep.trashItem = previous }
        #endif
        let m = manager(store: store)
        await m.restore()

        let outcome = await m.removeAndReport(done.id, deleteData: true)
        XCTAssertFalse(exists(path))
        #if os(macOS)
        XCTAssertEqual(outcome, .trashed)
        XCTAssertEqual(trashed.value, [path], "a finished payload goes through the Trash seam, not unlink")
        #endif
        await m.shutdown()
    }

    func testALegacyPartialIsTheDownloadsOwn() async {
        let dir = makeTempDir()
        let m = manager()
        let task = await m.add(source: url("https://e.test/old.iso"), saveDirectory: dir,
                               startPaused: true, suggestedName: "old.iso")
        var legacy = task
        legacy.resumeData = Data("cursor".utf8)
        let plan = DownloadManager.payloadPlan(for: legacy) { _ in false }
        XCTAssertEqual(plan.trash, [task.savePath], "resume data but no .goelpart: the final path is the partial")
        let fresh = DownloadManager.payloadPlan(for: task) { _ in false }
        XCTAssertEqual(fresh.trash, [])
    }

    func testPayloadPlanPerKind() {
        let dir = "/tmp/goel-plan"
        func plan(_ kind: DownloadSource, _ status: DownloadStatus) -> DownloadManager.PayloadPlan {
            let t = DownloadTask(source: kind, name: "f.bin", saveDirectory: dir, status: status)
            return DownloadManager.payloadPlan(for: t) { _ in false }
        }
        let ftp = url("ftp://e.test/f.bin"), hls = DownloadSource.hlsStream(URL(string: "https://e.test/a.m3u8")!)
        XCTAssertEqual(plan(ftp, .paused), .init(unlink: [dir + "/f.bin"]), "FTP resumes into savePath itself")
        XCTAssertEqual(plan(ftp, .completed), .init(trash: [dir + "/f.bin"]))
        XCTAssertEqual(plan(hls, .paused), .init(), "HLS segments are in the engine's work folder")
        XCTAssertEqual(plan(.magnet("magnet:?xt=urn:btih:abc"), .completed), .init(), "torrents are the engine's")
    }

    func testAFileThatSurvivesIsReportedOnce() async throws {
        let dir = makeTempDir()
        let m = manager()
        let task = await m.add(source: url("https://e.test/locked.bin"), saveDirectory: dir,
                               startPaused: true, suggestedName: "locked.bin")
        touch(task.savePath + ".goelpart")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir)

        let outcome = await m.removeAndReport(task.id, deleteData: true)
        guard case .keptOnDisk = outcome else { return XCTFail("expected keptOnDisk, got \(String(describing: outcome))") }
        let notices = await m.takeNotices()
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices.first?.taskID, task.id)
    }

    func testAnUnloadedTorrentsFilesAreNeverDeletedByName() async throws {
        let dir = makeTempDir()
        let m = manager()
        let task = await m.add(source: .magnet("magnet:?xt=urn:btih:\(String(repeating: "a", count: 40))&dn=Pack"),
                               saveDirectory: dir, startPaused: true, suggestedName: "Pack")
        try FileManager.default.createDirectory(atPath: task.savePath, withIntermediateDirectories: true)
        touch((task.savePath as NSString).appendingPathComponent("inner.bin"))

        let outcome = await m.removeAndReport(task.id, deleteData: true)
        guard case .keptOnDisk = outcome else { return XCTFail("expected keptOnDisk, got \(String(describing: outcome))") }
        XCTAssertTrue(exists(task.savePath), "no recursive delete of a folder the engine never loaded")
        let notices = await m.takeNotices()
        XCTAssertEqual(notices.count, 1)
    }

    func testOnlyTheTorrentEngineIsAskedToDeleteData() async {
        let http = DeleteFlagEngine(kind: .http), torrent = DeleteFlagEngine(kind: .torrent)
        let m = manager(http: http, torrent: torrent)
        let dir = makeTempDir()
        let file = await m.add(source: url("https://e.test/a.bin"), saveDirectory: dir)
        let magnet = await m.add(source: .magnet("magnet:?xt=urn:btih:\(String(repeating: "b", count: 40))"),
                                 saveDirectory: dir)
        await waitUntil { http.added.contains(file.id) && torrent.added.contains(magnet.id) }

        let fileOutcome = await m.removeAndReport(file.id, deleteData: true)
        let torrentOutcome = await m.removeAndReport(magnet.id, deleteData: true)
        XCTAssertEqual(http.removals.first?.1, false, "the manager owns HTTP payload deletion")
        XCTAssertEqual(torrent.removals.first?.1, true)
        XCTAssertEqual(fileOutcome, .nothingToDelete)
        XCTAssertEqual(torrentOutcome, .handledByEngine)
        let unknown = await m.removeAndReport(UUID(), deleteData: true)
        XCTAssertNil(unknown)
    }

    // MARK: 2 — reinsert (undo)

    func testReinsertBringsRowsBackWithTheirStateAndNeverDuplicates() async throws {
        let store = try PersistenceStore()
        let m = manager(store: store)
        let dir = makeTempDir()
        var running = DownloadTask(source: url("https://e.test/r.bin"), name: "r.bin", saveDirectory: dir,
                                   totalBytes: 100, bytesDownloaded: 40, downloadSpeed: 9, status: .downloading,
                                   resumeData: Data("cursor".utf8))
        running.connections = []
        let done = DownloadTask(source: url("https://e.test/d.bin"), name: "d.bin", saveDirectory: dir,
                                status: .completed, completedAt: Date())
        let failed = DownloadTask(source: url("https://e.test/f.bin"), name: "f.bin", saveDirectory: dir,
                                  status: .failed(.network("x")))
        let present = await m.add(source: url("https://e.test/p.bin"), saveDirectory: dir, startPaused: true)
        let sameSource = DownloadTask(source: present.source, name: "dup", saveDirectory: dir, status: .paused)

        await m.reinsert([running, done, failed, present, sameSource])

        let rows = await m.snapshot
        XCTAssertEqual(rows.count, 4, "an id or source already listed is skipped")
        let back = await m.task(running.id)
        XCTAssertEqual(back?.status, .paused, "nothing the engine held survived, so it does not restart itself")
        XCTAssertEqual(back?.resumeData, Data("cursor".utf8))
        XCTAssertEqual(back?.bytesDownloaded, 40)
        XCTAssertEqual(back?.downloadSpeed, 0)
        XCTAssertNil(back?.connections)
        let doneBack = await m.task(done.id)
        XCTAssertEqual(doneBack?.status, .completed)
        let failedBack = await m.task(failed.id)
        XCTAssertEqual(failedBack?.status, .failed(.network("x")))
        await m.shutdown()
        XCTAssertEqual(Set(try store.loadAllTasks().map(\.id)), [running.id, done.id, failed.id, present.id])
    }

    // MARK: 3 — rename moves only what is the download's

    func testRenamingAnUnfinishedHTTPDownloadMovesOnlyThePartial() async {
        let dir = makeTempDir()
        let m = manager()
        let task = await m.add(source: url("https://e.test/a.bin"), saveDirectory: dir,
                               startPaused: true, suggestedName: "a.bin")
        touch(task.savePath, "the user's file")
        touch(task.savePath + ".goelpart", "bytes")

        let result = await m.rename(task.id, to: "b.bin")
        guard case .renamed(let name) = result else { return XCTFail("\(result)") }
        let newPath = (dir as NSString).appendingPathComponent(name)
        XCTAssertTrue(exists(task.savePath), "the user's file stays where it was")
        XCTAssertFalse(exists(task.savePath + ".goelpart"))
        XCTAssertTrue(exists(newPath + ".goelpart"))
    }

    func testAStrangersPartialAtTheNewNameIsNeverAdopted() async {
        let dir = makeTempDir()
        let m = manager()
        let task = await m.add(source: url("https://e.test/a.bin"), saveDirectory: dir,
                               startPaused: true, suggestedName: "a.bin")
        touch(task.savePath + ".goelpart", "mine")
        let stranger = (dir as NSString).appendingPathComponent("b.bin.goelpart")
        touch(stranger, "someone else's")

        let result = await m.rename(task.id, to: "b.bin")
        guard case .renamed(let name) = result else { return XCTFail("\(result)") }
        XCTAssertNotEqual(name, "b.bin", "resume would otherwise continue from the stranger's bytes")
        XCTAssertEqual(try? String(contentsOfFile: stranger, encoding: .utf8), "someone else's")
        XCTAssertTrue(exists((dir as NSString).appendingPathComponent(name) + ".goelpart"))
    }

    func testFTPRenameMovesSavePath() {
        let t = DownloadTask(source: url("ftp://e.test/a.bin"), name: "a.bin", saveDirectory: "/d", status: .paused)
        let moves = DownloadManager.renameMoves(for: t, to: "/d/b.bin") { $0 == "/d/a.bin" }
        XCTAssertEqual(moves, [.init(from: "/d/a.bin", to: "/d/b.bin")])
    }

    func testAFailedMoveRollsTheEarlierOnesBack() {
        let dir = makeTempDir()
        let a = (dir as NSString).appendingPathComponent("a"), b = (dir as NSString).appendingPathComponent("b")
        touch(a)
        let moves: [DownloadManager.RenameMove] = [
            .init(from: a, to: b),
            .init(from: (dir as NSString).appendingPathComponent("missing"), to: (dir as NSString).appendingPathComponent("c")),
        ]
        XCTAssertNotNil(DownloadManager.perform(moves, fileManager: .default))
        XCTAssertTrue(exists(a), "the first move is undone")
        XCTAssertFalse(exists(b))
    }

    // MARK: 4 — inline credentials

    func testInlineHTTPSLoginIsStoredUnderTheLowercasedHost() async {
        let store = FakeCredentialStore()
        let m = manager(credentials: store)
        let source = await m.adoptInlineCredentials("https://alice:s3cret@Files.Example.TEST/a.bin")
        XCTAssertFalse(source?.locator.contains("s3cret") ?? true)
        XCTAssertEqual(store.credential(forHost: "files.example.test")?.password, "s3cret")
    }

    func testPlainHTTPLoginIsRefusedWithANotice() async {
        let store = FakeCredentialStore()
        let m = manager(credentials: store)
        let source = await m.adoptInlineCredentials("http://bob:pw@e.test/a.bin")
        XCTAssertNotNil(source)
        XCTAssertTrue(store.allCredentials().isEmpty)
        let notices = await m.takeNotices()
        XCTAssertEqual(notices.count, 1)
    }

    func testAnExistingLoginIsKeptUnlessReplacing() async {
        let store = FakeCredentialStore()
        _ = store.setCredential(username: "old", password: "1", host: "e.test")
        let m = manager(credentials: store)
        await m.adoptInlineCredentials("https://new:2@e.test/a")
        XCTAssertEqual(store.credential(forHost: "e.test")?.username, "old")
        await m.adoptInlineCredentials("https://new:2@e.test/a", replaceExisting: true)
        XCTAssertEqual(store.credential(forHost: "e.test")?.username, "new")
    }

    func testAFeedItemsLoginIsAdoptedWhenItIsAdded() async {
        let store = FakeCredentialStore()
        let m = manager(credentials: store)
        let raw = "https://feed:pw@e.test/ep1.mp3"
        let source = DownloadSource.parse(raw)!
        let fetch = AutomationCore.FeedFetch(startPaused: true, candidates: [
            .init(key: "feed|ep1", source: source, dedupKey: source.dedupKey),
        ])
        await m.runAutomation(feeds: [fetch], inlineLogins: [source.dedupKey: raw])
        XCTAssertEqual(store.credential(forHost: "e.test")?.username, "feed")
        let rows = await m.snapshot
        XCTAssertEqual(rows.count, 1)
        XCTAssertFalse(rows[0].source.locator.contains("pw"))
    }

    // MARK: 5 — scanner tri-state

    private func completeOne(_ m: DownloadManager, _ http: RecordingEngine, dir: String) async -> DownloadTask {
        let task = await m.add(source: url("https://e.test/s.bin"), saveDirectory: dir, suggestedName: "s.bin")
        touch(task.savePath)
        await waitUntil { http.log.contains { $0.hasPrefix("add:") } }
        http.emit(.statusChanged(.completed), for: task.id)
        await waitUntil { await m.task(task.id)?.status == .completed }
        return task
    }

    func testAScannerErrorIsNotADetection() async {
        var settings = AppSettings()
        settings.antivirusEnabled = true
        settings.antivirusExecutablePath = "/usr/bin/true"
        let http = RecordingEngine(kind: .http)
        let m = manager(http: http, settings: settings, scanner: FakeScanner(verdict: .error("timed out")))
        let task = await completeOne(m, http, dir: makeTempDir())
        await waitUntil { await m.task(task.id)?.scanVerdict != nil }
        let verdict = await m.task(task.id)?.scanVerdict
        XCTAssertEqual(verdict, "error")
        let notices = await m.takeNotices()
        XCTAssertTrue(notices.contains { $0.taskID == task.id && $0.message.contains("timed out") })
    }

    func testAnInfectedFileIsFlagged() async {
        var settings = AppSettings()
        settings.antivirusEnabled = true
        let http = RecordingEngine(kind: .http)
        let m = manager(http: http, settings: settings, scanner: FakeScanner(verdict: .infected))
        let task = await completeOne(m, http, dir: makeTempDir())
        await waitUntil { await m.task(task.id)?.scanVerdict != nil }
        let verdict = await m.task(task.id)?.scanVerdict
        XCTAssertEqual(verdict, "flagged")
    }

    func testAntivirusScannerReportsTriState() async {
        let refused = await AntivirusScanner.scan(path: "/tmp/x", executablePath: "/nonexistent/scan",
                                                 argumentTemplate: "%path%")
        guard case .error = refused else { return XCTFail("\(refused)") }
        let clean = await AntivirusScanner.scan(path: "/tmp/x", executablePath: "/usr/bin/true",
                                                argumentTemplate: "")
        XCTAssertEqual(clean, .clean)
        let infected = await AntivirusScanner.scan(path: "/tmp/x", executablePath: "/usr/bin/false",
                                                   argumentTemplate: "")
        XCTAssertEqual(infected, .infected)
    }

    // MARK: 6 — disk full is never auto-retried

    func testDiskFullTextIsRecognised() {
        XCTAssertTrue(DownloadManager.isDiskFull(.diskFull(needed: 1, available: 0)))
        XCTAssertTrue(DownloadManager.isDiskFull(.unknown("ffmpeg: No space left on device")))
        XCTAssertTrue(DownloadManager.isDiskFull(.network("write failed: ENOSPC")))
        XCTAssertTrue(DownloadManager.isDiskFull(.unknown("There is not enough disk space.")))
        XCTAssertFalse(DownloadManager.isDiskFull(.network("connection reset")))
        XCTAssertFalse(DownloadManager.isDiskFull(.httpStatus(507)))
    }

    // MARK: 7 — settings persistence failures

    func testBlockedSettingsWritesAreAnnouncedAtMostOnceAMinute() async {
        let m = manager()
        await m.forceSettingsLoadFailedForTesting()
        await m.setProfile("Low")
        await m.setSpeedLimitEnabled(true)
        let notices = await m.takeNotices()
        XCTAssertEqual(notices.count, 1)
    }

    func testASecondBackupNeverReplacesTheFirst() throws {
        let store = try PersistenceStore()
        let first = Data("first".utf8), second = Data("second".utf8)
        try store.writeRawRow(table: "settings", key: "app", data: first)
        XCTAssertTrue(try store.backupSettingsRow())
        try store.writeRawRow(table: "settings", key: "app", data: second)
        XCTAssertFalse(try store.backupSettingsRow())
        XCTAssertEqual(try store.loadSettingsBackup(), first)
    }

    func testRestoreSettingsBackupAdoptsTheKeptRow() async throws {
        let store = try PersistenceStore()
        var saved = AppSettings()
        saved.selectedProfileName = "Low"
        try store.saveSettings(saved)
        try store.backupSettingsRow()
        try store.writeRawRow(table: "settings", key: "app", data: Data("garbage".utf8))

        let m = manager(store: store)
        await m.restore()
        let before = await m.currentSettings.selectedProfileName
        XCTAssertNotEqual(before, "Low")
        try await m.restoreSettingsBackup()
        let after = await m.currentSettings.selectedProfileName
        XCTAssertEqual(after, "Low")
        await m.shutdown()
        XCTAssertEqual(try store.loadSettings()?.selectedProfileName, "Low")
        XCTAssertNil(try store.loadSettingsBackup())
    }

    // MARK: 8 — quarantine

    #if os(macOS)
    private func isQuarantined(_ path: String) -> Bool {
        getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) > 0
    }

    func testATopLevelSymlinkIsNeverFlagged() throws {
        let dir = makeTempDir()
        let outside = (dir as NSString).appendingPathComponent("outside.txt")
        touch(outside)
        let link = (dir as NSString).appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside)
        XCTAssertEqual(Quarantine.mark(URL(fileURLWithPath: link), sourceURL: nil, referrer: nil), 0)
        XCTAssertFalse(isQuarantined(outside))
    }

    func testARelaunchedCompleteTorrentIsNotReQuarantined() async throws {
        let dir = makeTempDir()
        let path = (dir as NSString).appendingPathComponent("Pack.bin")
        touch(path)
        let store = try PersistenceStore()
        let seeded = DownloadTask(source: .magnet("magnet:?xt=urn:btih:\(String(repeating: "c", count: 40))"),
                                  name: "Pack.bin", saveDirectory: dir, totalBytes: 1, bytesDownloaded: 1,
                                  status: .seeding)
        try store.saveTask(seeded)
        let torrent = RecordingEngine(kind: .torrent)
        let m = manager(torrent: torrent, store: store)
        await m.restore()
        await waitUntil { torrent.log.contains { $0.hasPrefix("add:") } }
        torrent.emit(.statusChanged(.verifying), for: seeded.id)
        torrent.emit(.statusChanged(.seeding), for: seeded.id)
        await waitUntil { await m.task(seeded.id)?.status == .seeding }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(isQuarantined(path), "picking a finished torrent back up is not a download")
        await m.shutdown()
    }

    func testATorrentFinishingNowIsQuarantined() async {
        let dir = makeTempDir()
        let torrent = RecordingEngine(kind: .torrent)
        let m = manager(torrent: torrent)
        let task = await m.add(source: .magnet("magnet:?xt=urn:btih:\(String(repeating: "d", count: 40))"),
                               saveDirectory: dir, suggestedName: "Fresh.bin")
        touch(task.savePath)
        await waitUntil { torrent.log.contains { $0.hasPrefix("add:") } }
        torrent.emit(.statusChanged(.downloading), for: task.id)
        torrent.emit(.statusChanged(.seeding), for: task.id)
        let flagged = await waitUntil { self.isQuarantined(task.savePath) }
        XCTAssertTrue(flagged)
    }
    #endif

    // MARK: 9 — import

    func testImportKeepsTheCurrentAuditShutdownAndTorrentDeletion() {
        var current = AppSettings(), imported = AppSettings()
        current.auditLogEnabled = true
        current.autoShutdownAction = "none"
        current.btAutoDeleteTorrent = false
        imported.auditLogEnabled = false
        imported.autoShutdownAction = "shutdown"
        imported.btAutoDeleteTorrent = true
        let safe = DownloadManager.sanitizedImportedSettings(imported, current: current)
        XCTAssertTrue(safe.auditLogEnabled)
        XCTAssertEqual(safe.autoShutdownAction, "none")
        XCTAssertFalse(safe.btAutoDeleteTorrent)
    }

    func testImportRejectsLocalTorrentFiles() async throws {
        let local = DownloadTask(source: .torrentFile(URL(fileURLWithPath: "/etc/x.torrent")), name: "x",
                                 saveDirectory: "/tmp", status: .paused)
        let remote = DownloadTask(source: url("https://e.test/ok.bin"), name: "ok.bin", saveDirectory: "/tmp",
                                  status: .paused)
        let data = try JSONEncoder().encode(AppExport(settings: AppSettings(), tasks: [local, remote]))
        let m = manager()
        let added = try await m.importEnvelope(data)
        XCTAssertEqual(added, 1)
        let local2 = await m.task(local.id)
        XCTAssertNil(local2)
    }

    // MARK: 10 — a deliberate restart drops the engine's cursor

    func testResetEngineStateRemovesWithoutDeletingAndForgetsTheStart() async {
        let http = DeleteFlagEngine(kind: .http)
        let m = manager(http: http)
        let task = await m.add(source: url("https://e.test/r.bin"), saveDirectory: makeTempDir())
        await waitUntil { http.added.contains(task.id) }
        await m.resetEngineState(task.id)
        XCTAssertEqual(http.removals.map(\.1), [false])
        let started = await m.isEngineStartedForTesting(task.id)
        XCTAssertFalse(started, "the next promotion must add afresh, not resume")
    }

    // MARK: 13 — notices

    func testMissingFileNoticeIsAnError() async throws {
        let dir = makeTempDir()
        let store = try PersistenceStore()
        let gone = DownloadTask(source: url("https://e.test/g.bin"), name: "g.bin", saveDirectory: dir,
                                status: .completed, completedAt: Date())
        try store.saveTask(gone)
        let m = manager(store: store)
        await m.restore()
        await waitUntil { await m.hasPendingNotices }
        let notices = await m.takeNotices()
        XCTAssertEqual(notices.first?.isError, true, "a busy toast queue must not drop it first")
        await m.shutdown()
    }
}

final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T { lock.withLock { _value } }
    func mutate(_ body: (inout T) -> Void) { lock.withLock { body(&_value) } }
}
