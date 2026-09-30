import XCTest
@testable import GoelCore

/// Records every call in order, so a test can prove `refresh` lands before `resume`.
final class RecordingEngine: DownloadEngine, @unchecked Sendable {
    let kind: DownloadKind
    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]
    private var buffered: [UUID: [EngineEvent]] = [:]
    private var _log: [String] = []
    private var _refreshed: [DownloadTask] = []
    private var _shutdowns = 0
    let shutdownDelay: UInt64

    init(kind: DownloadKind, shutdownDelayNanos: UInt64 = 0) {
        self.kind = kind
        self.shutdownDelay = shutdownDelayNanos
    }

    private func record(_ entry: String) { lock.lock(); _log.append(entry); lock.unlock() }

    func add(_ task: DownloadTask) async { record("add:\(task.name)") }
    func pause(_ id: DownloadTask.ID) async { record("pause") }
    func resume(_ id: DownloadTask.ID) async { record("resume") }
    func remove(_ id: DownloadTask.ID, deleteData: Bool) async { record("remove") }
    func applyLimits(_ profile: TrafficProfile) async {}

    func refresh(_ task: DownloadTask) async {
        lock.lock(); _refreshed.append(task); _log.append("refresh:\(task.name)"); lock.unlock()
    }

    func shutdown() async {
        if shutdownDelay > 0 { try? await Task.sleep(nanoseconds: shutdownDelay) }
        lock.lock(); _shutdowns += 1; _log.append("shutdown"); lock.unlock()
    }

    func events(for id: DownloadTask.ID) -> AsyncStream<EngineEvent> {
        let (stream, continuation) = AsyncStream<EngineEvent>.makeStream(bufferingPolicy: .unbounded)
        lock.lock()
        let pending = buffered[id] ?? []
        buffered[id] = nil
        continuations[id] = continuation
        lock.unlock()
        for event in pending { continuation.yield(event) }
        return stream
    }

    func emit(_ event: EngineEvent, for id: UUID) {
        lock.lock()
        if let continuation = continuations[id] {
            lock.unlock()
            continuation.yield(event)
        } else {
            buffered[id, default: []].append(event)
            lock.unlock()
        }
    }

    var log: [String] { lock.lock(); defer { lock.unlock() }; return _log }
    var refreshed: [DownloadTask] { lock.lock(); defer { lock.unlock() }; return _refreshed }
    var shutdowns: Int { lock.lock(); defer { lock.unlock() }; return _shutdowns }
}

struct FailingScanner: FileScanning {
    func scan(path: String, executablePath: String, argumentTemplate: String) async -> Bool { false }
}

final class DownloadManagerLifecycleTests: XCTestCase {

    private var tempDirs: [String] = []

    override func tearDownWithError() throws {
        for dir in tempDirs {
            _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir)
            try? FileManager.default.removeItem(atPath: dir)
        }
        tempDirs.removeAll()
    }

    private func makeTempDir() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goel-lifecycle-\(UUID().uuidString)").path
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

    // MARK: ENG-1 — engines get the current task

    func testResumeAfterRenameRefreshesTheEngineFirst() async {
        let http = RecordingEngine(kind: .http)
        let manager = DownloadManager(httpEngine: http, torrentEngine: RecordingEngine(kind: .torrent))
        let dir = makeTempDir()
        let task = await manager.add(source: url("https://example.test/a.iso"), saveDirectory: dir)
        await waitUntil { http.log.contains("add:a.iso") }
        await manager.pause(task.id)

        let result = await manager.rename(task.id, to: "b.iso")
        XCTAssertEqual(result, .renamed("b.iso"))
        XCTAssertEqual(http.refreshed.last?.name, "b.iso", "a stopped task's rename reaches the engine at once")

        await manager.resume(task.id)
        await waitUntil { http.log.last == "resume" }
        let log = http.log
        XCTAssertEqual(Array(log.suffix(2)), ["refresh:b.iso", "resume"],
                       "resume must be preceded by a refresh carrying the new name")
    }

    func testLimitHeadersAndCookiesRefreshAStoppedTask() async {
        let http = RecordingEngine(kind: .http)
        let manager = DownloadManager(httpEngine: http, torrentEngine: RecordingEngine(kind: .torrent))
        let task = await manager.add(source: url("https://example.test/f.bin"), saveDirectory: makeTempDir())
        await waitUntil { http.log.contains("add:f.bin") }
        await manager.pause(task.id)

        await manager.setTaskSpeedLimit(1000, task: task.id)
        XCTAssertEqual(http.refreshed.last?.speedLimitBytesPerSec, 1000)
        await manager.setRequestOptions(referer: nil, headers: ["X-Token": "1"], task: task.id)
        XCTAssertEqual(http.refreshed.last?.requestHeaders?["X-Token"], "1")
        await manager.setCookies("sid=abc", host: nil, source: .manual, task: task.id)
        XCTAssertEqual(http.refreshed.last?.cookieHeader, "sid=abc")
    }

    func testMutatingANeverStartedTaskDoesNotRefresh() async {
        let http = RecordingEngine(kind: .http)
        let manager = DownloadManager(httpEngine: http, torrentEngine: RecordingEngine(kind: .torrent))
        let task = await manager.add(source: url("https://example.test/g.bin"),
                                     saveDirectory: makeTempDir(), startPaused: true)
        await manager.setTaskSpeedLimit(500, task: task.id)
        XCTAssertTrue(http.refreshed.isEmpty, "an engine that never saw the task has no copy to refresh")
    }

    // MARK: ENG-13 — shutdown reaches every engine

    func testShutdownAwaitsEveryDistinctEngine() async {
        let shared = RecordingEngine(kind: .http, shutdownDelayNanos: 100_000_000)
        let hls = RecordingEngine(kind: .hls), ftp = RecordingEngine(kind: .ftp), sftp = RecordingEngine(kind: .sftp)
        let manager = DownloadManager(httpEngine: shared, torrentEngine: shared,
                                      hlsEngine: hls, ftpEngine: ftp, sftpEngine: sftp)
        await manager.shutdown()
        XCTAssertEqual(shared.shutdowns, 1, "one instance serving two kinds is shut down once")
        XCTAssertEqual([hls.shutdowns, ftp.shutdowns, sftp.shutdowns], [1, 1, 1])
    }

    func testEngineShutdownIsBoundedByADeadline() async {
        let stuck = RecordingEngine(kind: .http, shutdownDelayNanos: 30_000_000_000)
        let manager = DownloadManager(httpEngine: stuck, torrentEngine: RecordingEngine(kind: .torrent))
        let started = Date()
        await manager.shutdownEngines(deadline: 0.3)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "a hung engine must not hold quit hostage")
    }

    // MARK: ENG-10 — no auto-retry against a full disk

    func testAutoRetrySkipsDiskFullButNotNetworkErrors() async {
        let http = RecordingEngine(kind: .http)
        var settings = AppSettings()
        settings.autoRetryEnabled = true
        settings.autoRetryMaxAttempts = 3
        let manager = DownloadManager(httpEngine: http, torrentEngine: RecordingEngine(kind: .torrent),
                                      settings: settings)
        let full = await manager.add(source: url("https://example.test/full.bin"), saveDirectory: makeTempDir())
        let flaky = await manager.add(source: url("https://example.test/flaky.bin"), saveDirectory: makeTempDir())
        await waitUntil { http.log.contains("add:full.bin") && http.log.contains("add:flaky.bin") }

        http.emit(.failed(.diskFull(needed: 10, available: 1)), for: full.id)
        http.emit(.failed(.network("reset")), for: flaky.id)
        await waitUntil { await manager.task(flaky.id)?.retryAttempt == 1 }

        let fullRow = await manager.task(full.id)
        XCTAssertNil(fullRow?.retryAttempt, "disk full is not retried automatically")
        let flakyRow = await manager.task(flaky.id)
        XCTAssertEqual(flakyRow?.retryAttempt, 1)
        await manager.shutdown()
    }

    // MARK: ENG-15 — relaunch keeps the queue

    func testNormalizeRestoredKeepsQueueAndRequeuesInterruptedWork() {
        func restored(_ status: DownloadStatus) -> DownloadStatus {
            let t = DownloadTask(source: .url(URL(string: "https://e.test/x")!), name: "x",
                                 saveDirectory: "/tmp", status: status)
            return DownloadManager.normalizeRestored(t).status
        }
        XCTAssertEqual(restored(.queued), .queued)
        XCTAssertEqual(restored(.downloading), .queued)
        XCTAssertEqual(restored(.seeding), .queued)
        XCTAssertEqual(restored(.requestingMetadata), .queued)
        XCTAssertEqual(restored(.paused), .paused, "a user pause survives a relaunch")
        XCTAssertEqual(restored(.completed), .completed)
    }

    // MARK: FAIL-2 — remove-with-data

    func testRemoveWithDataDeletesAPayloadTheEngineNeverSaw() async throws {
        let store = try PersistenceStore()
        let dir = makeTempDir()
        let path = (dir as NSString).appendingPathComponent("done.bin")
        FileManager.default.createFile(atPath: path, contents: Data("x".utf8))
        let done = DownloadTask(source: url("https://example.test/done.bin"), name: "done.bin",
                                saveDirectory: dir, status: .completed, completedAt: Date())
        try store.saveTask(done)
        let http = RecordingEngine(kind: .http)
        let manager = DownloadManager(httpEngine: http, torrentEngine: RecordingEngine(kind: .torrent),
                                      store: store)
        await manager.restore()

        await manager.remove(done.id, deleteData: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                       "a row restored at launch was never handed to the engine, so the manager deletes it")
        let notices = await manager.takeNotices()
        XCTAssertTrue(notices.isEmpty)
        await manager.shutdown()
    }

    func testRemoveWithDataReportsAFileThatStaysOnDisk() async throws {
        let dir = makeTempDir()
        let manager = DownloadManager(httpEngine: RecordingEngine(kind: .http),
                                      torrentEngine: RecordingEngine(kind: .torrent))
        let task = await manager.add(source: url("https://example.test/locked.bin"), saveDirectory: dir,
                                     startPaused: true, suggestedName: "locked.bin")
        FileManager.default.createFile(atPath: task.savePath, contents: Data("x".utf8))
        // A read-only folder: the file can't be unlinked, like a locked share.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir)
        await manager.remove(task.id, deleteData: true)

        let notices = await manager.takeNotices()
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices.first?.taskID, task.id)
        XCTAssertTrue(notices.first?.isError ?? false)
        XCTAssertTrue(notices.first?.message.contains("still on disk") ?? false)
        let again = await manager.takeNotices()
        XCTAssertTrue(again.isEmpty, "takeNotices drains")
    }

    func testRemoveWithDataNeverDeletesTheSaveFolderItself() async {
        let dir = makeTempDir()
        let task = DownloadTask(source: url("https://e.test/x"), name: "", saveDirectory: dir)
        let manager = DownloadManager(httpEngine: RecordingEngine(kind: .http),
                                      torrentEngine: RecordingEngine(kind: .torrent))
        await manager.removeLeftoverPayload(task)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir))
    }

    // MARK: PERF-4 — newest-only snapshots

    func testSnapshotStreamKeepsOnlyTheNewest() async {
        let manager = DownloadManager(httpEngine: RecordingEngine(kind: .http),
                                      torrentEngine: RecordingEngine(kind: .torrent))
        let stream = await manager.updates()
        for n in 0..<5 {
            _ = await manager.add(source: url("https://example.test/\(n).bin"),
                                  saveDirectory: makeTempDir(), startPaused: true)
        }
        var iterator = stream.makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.count, 5, "a slow consumer gets the latest queue, not a backlog")
    }

    // MARK: FAIL-13 — post-download failures are visible

    private func completingManager(settings: AppSettings, scanner: any FileScanning = FailingScanner())
        -> (DownloadManager, RecordingEngine) {
        let http = RecordingEngine(kind: .http)
        let manager = DownloadManager(httpEngine: http, torrentEngine: RecordingEngine(kind: .torrent),
                                      settings: settings, scanner: scanner)
        return (manager, http)
    }

    private func complete(_ manager: DownloadManager, _ engine: RecordingEngine,
                          name: String, in dir: String, contents: Data = Data("x".utf8)) async -> DownloadTask {
        let task = await manager.add(source: url("https://example.test/\(name)"), saveDirectory: dir,
                                     suggestedName: name)
        FileManager.default.createFile(atPath: task.savePath, contents: contents)
        await waitUntil { engine.log.contains { $0.hasPrefix("add:") } }
        engine.emit(.statusChanged(.completed), for: task.id)
        await waitUntil { await manager.task(task.id)?.status == .completed }
        return task
    }

    func testUnrunnableScannerIsAnErrorNotADetection() async {
        var settings = AppSettings()
        settings.antivirusEnabled = true
        settings.antivirusExecutablePath = "/nonexistent/goel-scanner"
        let (manager, http) = completingManager(settings: settings)
        let task = await complete(manager, http, name: "scan.bin", in: makeTempDir())
        let verdict = await manager.task(task.id)?.scanVerdict
        XCTAssertEqual(verdict, "error")
        let notices = await manager.takeNotices()
        XCTAssertTrue(notices.contains { $0.taskID == task.id && $0.isError })
    }

    func testFailedScriptIsReported() async {
        var settings = AppSettings()
        settings.postDownloadScriptEnabled = true
        settings.postDownloadScriptPath = "/usr/bin/true"
        let (manager, http) = completingManager(settings: settings)
        let task = await complete(manager, http, name: "s.bin", in: makeTempDir())
        let reported = await waitUntil {
            await manager.hasPendingNotices
        }
        XCTAssertTrue(reported)
        let notices = await manager.takeNotices()
        XCTAssertTrue(notices.contains { $0.taskID == task.id && $0.message.contains("script") })
    }

    #if os(macOS)
    func testCorruptArchiveExtractIsReported() async {
        var settings = AppSettings()
        settings.postDownloadExtractArchives = true
        let (manager, http) = completingManager(settings: settings)
        let task = await complete(manager, http, name: "bad.zip", in: makeTempDir(),
                                  contents: Data("definitely not a zip".utf8))
        let reported = await waitUntil(timeout: 10) { await manager.hasPendingNotices }
        XCTAssertTrue(reported)
        let notices = await manager.takeNotices()
        XCTAssertTrue(notices.contains { $0.taskID == task.id })
    }

    // MARK: SEC-1 — completion quarantines the payload

    func testCompletedDownloadIsQuarantined() async {
        let (manager, http) = completingManager(settings: AppSettings())
        let task = await complete(manager, http, name: "Invoice.dmg", in: makeTempDir())
        XCTAssertGreaterThan(getxattr(task.savePath, "com.apple.quarantine", nil, 0, 0, 0), 0,
                             "Gatekeeper only checks files that carry the flag")
    }
    #endif
}
