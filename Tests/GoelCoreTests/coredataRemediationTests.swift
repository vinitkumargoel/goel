import XCTest
@testable import GoelCore

/// Regression cover for the core data paths (CSV export, snapshot fold, segmented resume): each case
/// guards untrusted input that used to reach trapping arithmetic or a spreadsheet as a live formula.
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

    /// `CustomStringConvertible`, not `LocalizedError`: XCTest renders thrown errors with
    /// `String(describing:)`, so an `errorDescription` never reaches the log — just `PollTimeout()`.
    private struct PollTimeout: Error, CustomStringConvertible {
        var description: String {
            "the wait logged above never held — assertions after it were skipped, "
                + "not evaluated, and say nothing about this failure"
        }
    }

    /// Poll until the predicate holds or the deadline passes, THROWING as well as failing: files are
    /// preallocated, so later assertions compare equal-length garbage. `describe` names what was seen.
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

    /// ``SnapshotReducer/reduce(_:_:_:)`` built carry-over state with `Dictionary(uniqueKeysWithValues:)`,
    /// which TRAPS on a repeated key — an untrusted backup envelope with two tasks per id killed the app.
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

    /// ``DownloadManager/importEnvelope(_:)`` deduped only on `source.dedupKey`, so two entries sharing a
    /// task id both queued; `taskIndex` keys on id, making the first an unreachable zombie feeding CDP-1.
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

    /// Refining the name on EVERY run made each resume re-run `PathSafety.uniqueName`, stepping over the
    /// task's own partial; `destinationHoldsPreallocation` then refused the cursor and restarted at zero.
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
        // Generous because it is wall-clock the transfer needs: 256 chunks 25ms apart ⇒ ~7s floor,
        // ~15s on arm64, and 30s failed on every (2x slower) CI run. A passing run returns early.
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

    /// The post-probe rename called `PathSafety.uniqueName` unconditionally, so a user who chose
    /// **Overwrite** still got `name (1).mp4` whenever a `Content-Disposition` name collided.
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

    /// `cursor.completed.reduce(0, +)` traps on `Int64` overflow, and the cursor arrives verbatim from an
    /// imported backup (`sanitizedForImport` skips `resumeData`). Nonsense reports 0 → preflight full size.
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

    /// `field` quoted only for `,` `"` `\n` `\r`, never the first character — so a server-supplied
    /// name evaluated as a formula in Excel/Numbers/Sheets. Quotes are stripped first, hence the apostrophe.
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

    /// One ``RateLimiter`` shared by several writers paces their SUM — what `downloadPacer` relies on.
    /// Before it, a fresh limiter per transfer let N downloads reach N × the profile cap.
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

    /// An uncapped limiter still forwards to the pacer behind it — the point of the chain: a task
    /// with no limit of its own is still bound by the engine-wide ceiling.
    func testAnUncappedLimiterStillChargesTheChainedPacer() async throws {
        let shared = RateLimiter(bytesPerSecond: 100_000)
        let perTask = RateLimiter(bytesPerSecond: 0, next: shared)
        let started = Date()
        await perTask.pace(150_000)
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 1.0,
                             "150 KB at the shared 100 KB/s must sleep, not sail through")
    }

    /// A transfer with no limit of its own must pace through the engine-wide pacer ITSELF, not a copy —
    /// that is what makes the profile cap hold in sum; a task limit is layered in front, not merged.
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
