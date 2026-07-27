import XCTest
@testable import GoelCore

/// Regression cover for the core data paths — the CSV export leaf, the snapshot
/// fold, and the segmented-resume machinery.
///
/// Every case here guards a boundary where *untrusted input* (a server header, a
/// backup envelope, a stored resume cursor, a server-suggested filename) used to
/// reach arithmetic or a dictionary initializer that traps, or reach a spreadsheet
/// as a live formula. The bar for each: it must fail against the old behaviour.
final class CoreDataPathsRemediationTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        StubURLProtocol.forceNext429s(0)
        StubURLProtocol.resetSeenUserAgents()
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    // MARK: Helpers

    private func makeEngine(profile: TrafficProfile = .high) -> HTTPEngine {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return HTTPEngine(configuration: config, profile: profile)
    }

    private func deterministicData(_ count: Int) -> Data {
        var data = Data(capacity: count)
        for i in 0..<count { data.append(UInt8((i * 31 + 7) & 0xFF)) }
        return data
    }

    private func task(_ id: UUID, _ name: String, _ status: DownloadStatus,
                      scan: String? = nil) -> DownloadTask {
        DownloadTask(id: id, source: .url(URL(string: "https://e/\(name)")!),
                     name: name, saveDirectory: "/tmp", status: status, scanVerdict: scan)
    }

    private func env() -> ReducerEnv {
        ReducerEnv(notify: NotifyPrefs(onAdded: false, onCompleted: true,
                                       onFailed: true, onlyWhenInactive: false),
                   isAppActive: false, autoShutdownAction: "none")
    }

    /// `CustomStringConvertible`, not `LocalizedError`: XCTest renders a thrown error
    /// with `String(describing:)`, so an `errorDescription` never reaches the log and
    /// the reader gets a bare `PollTimeout()` to guess at.
    private struct PollTimeout: Error, CustomStringConvertible {
        var description: String {
            "the wait logged above never held — assertions after it were skipped, "
                + "not evaluated, and say nothing about this failure"
        }
    }

    /// Poll a predicate until it holds or the deadline passes — a real download's
    /// pacing is not something a fixed `sleep` can pin down.
    ///
    /// Throws as well as failing, so a caller stops at the timeout. Every assertion
    /// after a wait that did not hold is reading half-finished state: the file these
    /// tests check is preallocated to its full size before a byte of it is written,
    /// so a content comparison against an unfinished download reports two operands of
    /// identical length and leaves you staring at `"4194304 bytes" is not equal to
    /// ("4194304 bytes")`. The timeout is the finding; the cascade behind it is noise.
    ///
    /// `describe` is sampled only on failure, and says what the predicate last saw —
    /// a download that is merely slower than the budget and one that has wedged both
    /// time out, and the difference is not otherwise recoverable from a CI log.
    private func poll(timeout: TimeInterval, _ predicate: @Sendable () -> Bool,
                      describe: @Sendable () -> String = { "" },
                      file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let observed = describe()
        XCTFail("Timed out after \(Int(timeout))s waiting for condition"
                + (observed.isEmpty ? "" : " — last observed \(observed)"),
                file: file, line: line)
        throw PollTimeout()
    }

    private func plan(name: String, totalBytes: Int64?, acceptsRanges: Bool,
                      segmentCount: Int, maxBytesPerSecond: Int64 = 0,
                      sharedLimiter: RateLimiter? = nil) -> TransferPlan {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return TransferPlan(
            url: URL(string: "https://example.test/\(name)")!,
            destination: tempDir.appendingPathComponent(name),
            totalBytes: totalBytes,
            acceptsRanges: acceptsRanges,
            etag: nil,
            lastModified: nil,
            existingResume: nil,
            segmentCount: segmentCount,
            session: URLSession(configuration: config),
            settings: RequestSettings(userAgent: "GoelTest/1.0", maxAttempts: 2, retryInterval: 0),
            maxBytesPerSecond: maxBytesPerSecond,
            sharedLimiter: sharedLimiter,
            flushSize: 64 * 1024
        )
    }

    // MARK: CDP-1 — a duplicate task id in a snapshot must not trap

    /// ``SnapshotReducer/reduce(_:_:_:)`` used to build its carry-over state with
    /// `Dictionary(uniqueKeysWithValues:)`, which TRAPS on a repeated key. A backup
    /// envelope is untrusted input and could carry two tasks under one id, so the
    /// first view-model tick after importing one killed the app.
    func testDuplicateTaskIdInSnapshotFoldsLastWinsWithoutTrapping() {
        let id = UUID()
        let out = SnapshotReducer.reduce(
            ReducerState(),
            [task(id, "first", .downloading), task(id, "second", .completed)],
            env())
        // Last-wins: the same rule the notification pass above it already reads by.
        XCTAssertEqual(out.state.lastStatuses[id], .completed)
        XCTAssertEqual(out.state.lastStatuses.count, 1)
    }

    /// The verdict half of the fold trapped identically — `compactMap` does not
    /// save it once both duplicates carry a `scanVerdict`.
    func testDuplicateTaskIdWithScanVerdictsDoesNotTrap() {
        let id = UUID()
        let seeded = SnapshotReducer.reduce(ReducerState(), [task(id, "a", .downloading)], env()).state
        let out = SnapshotReducer.reduce(
            seeded,
            [task(id, "a", .completed, scan: "flagged"), task(id, "a", .completed, scan: "flagged")],
            env())
        XCTAssertEqual(out.state.lastScanVerdicts[id], "flagged")
        XCTAssertEqual(out.state.lastScanVerdicts.count, 1)
        // Next tick sees the verdict already recorded, so nothing re-fires — the
        // flag-once rule survives a duplicated row.
        let again = SnapshotReducer.reduce(out.state, [task(id, "a", .completed, scan: "flagged")], env())
        XCTAssertTrue(again.notifications.isEmpty)
    }

    /// A `nil` verdict must still REMOVE the key, exactly as the old `compactMap`
    /// did — otherwise a cleared verdict would look like a repeat flag next tick.
    func testClearedScanVerdictRemovesTheKey() {
        let id = UUID()
        let flagged = SnapshotReducer.reduce(
            ReducerState(), [task(id, "a", .completed, scan: "flagged")], env()).state
        let cleared = SnapshotReducer.reduce(flagged, [task(id, "a", .completed)], env())
        XCTAssertNil(cleared.state.lastScanVerdicts[id])
    }

    // MARK: CDP-6 — an envelope carrying a duplicate task id must be refused

    /// ``DownloadManager/importEnvelope(_:)`` deduped only on `source.dedupKey`, so
    /// two entries sharing a task id both entered the queue. `taskIndex` keys on the
    /// id, so the first row became an unreachable zombie — never pausable, removable
    /// or retryable — and it fed the snapshot that tripped CDP-1.
    func testImportEnvelopeRefusesADuplicateTaskId() async throws {
        let manager = DownloadManager(
            httpEngine: FakeEngine(kind: .http),
            torrentEngine: FakeEngine(kind: .torrent),
            settings: AppSettings(defaultSaveDirectory: tempDir.path),
            store: nil)
        defer { Task { await manager.shutdown() } }

        let id = UUID()
        let envelope = AppExport(settings: AppSettings(defaultSaveDirectory: tempDir.path), tasks: [
            DownloadTask(id: id, source: .url(URL(string: "https://example.test/one.bin")!),
                         name: "one.bin", saveDirectory: tempDir.path),
            DownloadTask(id: id, source: .url(URL(string: "https://example.test/two.bin")!),
                         name: "two.bin", saveDirectory: tempDir.path)
        ])
        let added = try await manager.importEnvelope(JSONEncoder().encode(envelope))

        XCTAssertEqual(added, 1, "the second entry re-uses an id already in the queue")
        let snapshot = await manager.snapshot
        XCTAssertEqual(snapshot.count, 1)
        XCTAssertEqual(snapshot.filter { $0.id == id }.count, 1, "no zombie row")
        let resolved = await manager.index(of: id)
        XCTAssertNotNil(resolved, "the surviving row must stay reachable through the id index")
    }

    // MARK: CDP-2 — the post-probe rename must not walk past its own partial file

    /// The engine refined the on-disk name on EVERY run, including resumes. Once a
    /// first attempt had to bump past a colliding file, each resume re-ran
    /// `PathSafety.uniqueName` — which now also stepped over the task's own partial —
    /// so the cursor's bytes were no longer at the destination,
    /// ``SegmentedTransfer/destinationHoldsPreallocation`` refused the cursor, and the
    /// download restarted from byte zero under a fresh `(n)` name every cycle.
    func testResumeKeepsTheNameResolvedOnTheFirstAttempt() async throws {
        let payload = deterministicData(4 * 1024 * 1024)
        StubURLProtocol.set(.init(
            data: payload, supportsRanges: true, sendContentLength: true,
            etag: "\"rename\"", chunkSize: 16 * 1024, chunkDelayMicros: 25_000,
            contentType: "video/mp4",
            contentDisposition: "attachment; filename=\"Holiday Clip.mp4\""
        ))
        // An UNRELATED file already owns the server-suggested name, so the first
        // attempt must bump to "Holiday Clip (1).mp4" — the state that used to loop.
        let decoy = tempDir.appendingPathComponent("Holiday Clip.mp4")
        try Data("unrelated".utf8).write(to: decoy)

        let engine = makeEngine()
        let task = DownloadTask(source: .url(URL(string: "https://example.test/clip")!),
                                name: "clip", saveDirectory: tempDir.path)
        let names = NameLog()
        let bytes = ProgressLog()
        let stream = engine.events(for: task.id)
        let consumer = Task {
            for await event in stream {
                if case .nameResolved(let name) = event { names.append(name) }
                if case .progress(let done, _, _, _, _) = event { bytes.set(done) }
            }
        }

        await engine.add(task)
        // Pause on OBSERVED mid-flight progress rather than a fixed sleep, so the
        // pause can neither land before the first byte nor after the last one.
        try await poll(timeout: 10) { let n = bytes.get(); return n > 0 && n < Int64(payload.count) }
            describe: { "\(bytes.get())/\(payload.count) bytes — never caught in flight" }
        await engine.pause(task.id)
        try await Task.sleep(nanoseconds: 150_000_000)
        await engine.resume(task.id)
        let target = tempDir.appendingPathComponent("Holiday Clip (1).mp4")
        // Generous, because this budget is wall-clock the transfer genuinely needs
        // rather than slack: the stub paces 256 chunks 25ms apart, so ~7s is the
        // floor and an unloaded arm64 machine takes ~15s end to end. At 30s this
        // failed on every CI run — a hosted runner is upwards of 2x slower and sat
        // just the wrong side of the line. A passing run returns the moment the
        // predicate holds and pays none of this; only a real hang waits it out.
        try await poll(timeout: 120) {
            (try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) == payload.count
                && bytes.get() == Int64(payload.count)
        } describe: {
            "\(bytes.get())/\(payload.count) bytes reported, "
                + "\((try? target.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1) on disk"
        }
        consumer.cancel()

        XCTAssertEqual(names.all(), ["Holiday Clip (1).mp4"],
                       "the name is resolved once, on the first attempt — never again on resume")
        XCTAssertEqual(try Data(contentsOf: target), payload,
                       "the resumed download must land intact at the SAME path")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("Holiday Clip (2).mp4").path),
            "a resume must not orphan a partial file under a bumped name")
        XCTAssertEqual(try Data(contentsOf: decoy), Data("unrelated".utf8),
                       "the unrelated file that forced the bump is never touched")
    }

    // MARK: CDP-9 — the "when a file exists" picker must reach the engine's rename

    /// The engine's post-probe rename called `PathSafety.uniqueName` unconditionally,
    /// so a user who chose **Overwrite** still got `name (1).mp4` whenever a
    /// server-suggested `Content-Disposition` name collided.
    func testOverwritePolicyReachesTheEnginesPostProbeRename() async throws {
        let payload = deterministicData(64 * 1024)
        StubURLProtocol.set(.init(
            data: payload, supportsRanges: true, sendContentLength: true,
            etag: "\"ow\"", chunkSize: 16 * 1024, chunkDelayMicros: 0,
            contentType: "video/mp4",
            contentDisposition: "attachment; filename=\"Report.mp4\""
        ))
        let target = tempDir.appendingPathComponent("Report.mp4")
        try Data("stale".utf8).write(to: target)

        let engine = makeEngine()
        await engine.configureFileConflictPolicy("overwrite")
        let task = DownloadTask(source: .url(URL(string: "https://example.test/report")!),
                                name: "report", saveDirectory: tempDir.path)
        let bytes = ProgressLog()
        let stream = engine.events(for: task.id)
        let consumer = Task {
            for await event in stream {
                if case .progress(let done, _, _, _, _) = event { bytes.set(done) }
            }
        }
        await engine.add(task)
        try await poll(timeout: 15) { bytes.get() == Int64(payload.count) }
            describe: { "\(bytes.get())/\(payload.count) bytes reported" }
        consumer.cancel()

        XCTAssertEqual(try Data(contentsOf: target), payload,
                       "Overwrite must replace the existing file, as the picker promises")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("Report (1).mp4").path),
            "Overwrite must not fall back to the rename policy")
    }

    // MARK: CDP-3 / CDP-8 — impossible or extreme declared sizes must not trap

    /// `preallocate` converts the declared size with `UInt64(_:)`, which traps on a
    /// negative value — and the size is a parsed `Content-Length` / `Content-Range`.
    func testPreallocateRefusesANegativeDeclaredSize() {
        let url = tempDir.appendingPathComponent("negative.bin")
        XCTAssertThrowsError(try SegmentedTransfer.preallocate(url, size: -1))
        XCTAssertNoThrow(try SegmentedTransfer.preallocate(url, size: 0),
                         "a genuinely zero-byte file is still legitimate")
    }

    /// End-to-end: a plan built from a `-1` server size must degrade to a single
    /// stream and finish or throw — never trap inside the range math.
    func testNegativeDeclaredSizeDegradesToASingleStream() async throws {
        StubURLProtocol.set(.init(
            data: deterministicData(8 * 1024), supportsRanges: true, sendContentLength: true,
            etag: nil, chunkSize: 4 * 1024, chunkDelayMicros: 0
        ))
        let transfer = SegmentedTransfer(plan: plan(name: "negative-size.bin", totalBytes: -1,
                                                    acceptsRanges: true, segmentCount: 8))
        XCTAssertEqual(transfer.connectionCount, 1, "an impossible size means the size is unknown")
        let consumer = Task { for await _ in transfer.progress {} }
        // Completes or throws the size mismatch; the point is that it RETURNS.
        _ = try? await transfer.run()
        _ = await consumer.value
    }

    /// `(total + minSegment - 1) / minSegment` overflows — and traps — at the top of
    /// the `Int64` range. Both clamps were rewritten overflow-free.
    func testSegmentClampsSurviveExtremeAndEmptyTotals() {
        XCTAssertGreaterThanOrEqual(SegmentedTransfer.clampSegmentCount(8, total: .max), 1)
        XCTAssertEqual(SegmentedTransfer.clampSegmentCount(8, total: .max), 8,
                       "an enormous file is limited by the request, not by the size floor")
        XCTAssertEqual(SegmentedTransfer.clampSegmentCount(4, total: 0), 1)
        XCTAssertEqual(SegmentedTransfer.clampSegmentCount(4, total: 1), 1)

        let budget = ConnectionBudget()
        XCTAssertGreaterThanOrEqual(
            budget.resolveSegmentCount(total: .max, host: nil, profile: .high), 1)
        XCTAssertEqual(budget.resolveSegmentCount(total: 0, host: nil, profile: .high), 1)
    }

    // MARK: CDP-7 — an untrusted resume cursor must not overflow the byte sum

    /// `cursor.completed.reduce(0, +)` traps on `Int64` overflow, and the cursor
    /// arrives verbatim from an imported backup (`sanitizedForImport` does not touch
    /// `resumeData`). Nonsense now reports 0, so the caller preflights the FULL size.
    func testResumedBytesOnDiskRefusesAnOverflowingCursor() throws {
        let hostile = SegmentedTransfer.ResumeCursor(
            etag: nil, lastModified: nil, totalBytes: 1000,
            ranges: [SegmentedTransfer.Range64(start: 0, end: 499), SegmentedTransfer.Range64(start: 500, end: 999)],
            completed: [.max, .max])
        let data = try JSONEncoder().encode(hostile)
        XCTAssertEqual(HTTPEngine.resumedBytesOnDisk(data, total: 1000), 0)

        let negative = SegmentedTransfer.ResumeCursor(
            etag: nil, lastModified: nil, totalBytes: 1000,
            ranges: [SegmentedTransfer.Range64(start: 0, end: 999)], completed: [-5])
        XCTAssertEqual(HTTPEngine.resumedBytesOnDisk(try JSONEncoder().encode(negative), total: 1000), 0)
    }

    /// …and a well-formed cursor still reports its true sum, so a mostly-complete
    /// resume keeps preflighting only the remainder.
    func testResumedBytesOnDiskStillSumsAWellFormedCursor() throws {
        let cursor = SegmentedTransfer.ResumeCursor(
            etag: nil, lastModified: nil, totalBytes: 1000,
            ranges: [SegmentedTransfer.Range64(start: 0, end: 499), SegmentedTransfer.Range64(start: 500, end: 999)],
            completed: [400, 100])
        XCTAssertEqual(HTTPEngine.resumedBytesOnDisk(try JSONEncoder().encode(cursor), total: 1000), 500)
    }

    // MARK: CDP-4 — an exported history must never carry a live spreadsheet formula

    /// `field` quoted only for `,` `"` `\n` `\r`, and never looked at the first
    /// character. A download's name comes from the server's `Content-Disposition`
    /// and its locator is the raw URL, so an exported CSV opened in Excel / Numbers /
    /// Sheets evaluated whatever the far end put there. Quoting alone does not help —
    /// the spreadsheet strips the quotes before evaluating — hence the apostrophe.
    func testFormulaLeadInsAreNeutralised() {
        let dangerous = ["=cmd|'/c calc'!A1", "+1+1", "-2+3+cmd|'/c calc'!A1",
                         "@SUM(1+9)", "\tsomething", "\rsomething"]
        for raw in dangerous {
            let encoded = CSVEncoder.field(raw)
            XCTAssertTrue(encoded.hasPrefix("\"'"),
                          "\(raw) must be marked as text, not left as a live formula")
            XCTAssertTrue(encoded.hasSuffix("\""), "…and must stay a well-formed RFC-4180 field")
        }
        // Embedded quotes are still doubled inside the neutralised field.
        XCTAssertEqual(CSVEncoder.field("=HYPERLINK(\"http://evil\")"),
                       "\"'=HYPERLINK(\"\"http://evil\"\")\"")
    }

    /// Only a LEADING character makes a cell a formula — ordinary text is untouched,
    /// so the export stays readable.
    func testOnlyALeadingFormulaCharacterIsEscaped() {
        XCTAssertEqual(CSVEncoder.field("a=b"), "a=b")
        XCTAssertEqual(CSVEncoder.field("2 + 2"), "2 + 2")
        XCTAssertEqual(CSVEncoder.field(""), "")
        XCTAssertEqual(CSVEncoder.field("1024"), "1024")
    }

    // MARK: CDP-5 — the speed cap must hold across concurrent downloads

    /// One ``RateLimiter`` shared by several writers paces their SUM. This is the
    /// property the engine-wide `downloadPacer` relies on; before it existed a fresh
    /// limiter was built per transfer, so N downloads reached N × the profile cap.
    func testASharedLimiterPacesTheSumOfConcurrentWriters() async throws {
        let limiter = RateLimiter(bytesPerSecond: 100_000)
        let started = Date()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { await limiter.pace(50_000) }
            }
            await group.waitForAll()
        }
        // 200 KB at 100 KB/s ≈ 2 s. Asserted as a LOWER bound only, so a slow or
        // loaded machine cannot make this flaky.
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 1.5,
                             "concurrent writers must queue on one timeline, not each get the full cap")
    }

    /// An uncapped limiter still forwards to the pacer behind it — that is the whole
    /// point of the chain: a task with no limit of its own is still bound by the
    /// engine-wide ceiling.
    func testAnUncappedLimiterStillChargesTheChainedPacer() async throws {
        let shared = RateLimiter(bytesPerSecond: 100_000)
        let perTask = RateLimiter(bytesPerSecond: 0, next: shared)
        let started = Date()
        await perTask.pace(150_000)
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 1.0,
                             "150 KB at the shared 100 KB/s must sleep, not sail through")
    }

    /// A transfer with no limit of its own must pace through the engine-wide pacer
    /// ITSELF (not a private copy of it), which is what makes the profile cap hold
    /// in sum; a task limit is layered in front rather than merged into it.
    func testTransferAdoptsTheSharedPacerRatherThanRebuildingIt() {
        let shared = RateLimiter(bytesPerSecond: 1_000)

        XCTAssertNil(SegmentedTransfer.makeLimiter(
            plan(name: "u.bin", totalBytes: nil, acceptsRanges: false, segmentCount: 1)),
                     "no task limit and no engine pacer means genuinely unlimited")

        let adopted = SegmentedTransfer.makeLimiter(
            plan(name: "s.bin", totalBytes: nil, acceptsRanges: false, segmentCount: 1,
                 sharedLimiter: shared))
        XCTAssertTrue(adopted === shared,
                      "the engine-wide pacer is used as-is; a fresh per-transfer copy is the bug")

        let layered = SegmentedTransfer.makeLimiter(
            plan(name: "t.bin", totalBytes: nil, acceptsRanges: false, segmentCount: 1,
                 maxBytesPerSecond: 500, sharedLimiter: shared))
        XCTAssertNotNil(layered)
        XCTAssertFalse(layered === shared,
                       "a per-task limit must not be written onto the pacer its siblings share")
    }
}

/// Thread-safe log of the `.nameResolved` events an engine emitted.
private final class NameLog: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String] = []
    func append(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
    func all() -> [String] { lock.lock(); defer { lock.unlock() }; return names }
}

/// Thread-safe holder for the latest reported byte count.
private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Int64 = 0
    func set(_ value: Int64) { lock.lock(); bytes = value; lock.unlock() }
    func get() -> Int64 { lock.lock(); defer { lock.unlock() }; return bytes }
}
