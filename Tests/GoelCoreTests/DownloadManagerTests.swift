import XCTest
@testable import GoelCore

// MARK: - In-test fake engine

/// A controllable, networking-free ``DownloadEngine`` for driving the scheduler
/// deterministically. It records calls and lets the test inject events at will.
///
/// Events emitted before a subscriber attaches are buffered per task and replayed
/// on subscription, so tests never race the scheduler's (async) subscribe step.
final class FakeEngine: DownloadEngine, @unchecked Sendable {

    let kind: DownloadKind

    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]
    private var buffered: [UUID: [EngineEvent]] = [:]

    private var _added: [UUID] = []
    private var _resumed: [UUID] = []
    private var _paused: [UUID] = []
    private var _removed: [UUID] = []
    private var _applyLimits: [TrafficProfile] = []
    private var _filePriorities: [(FilePriority, Int, UUID)] = []

    init(kind: DownloadKind) {
        self.kind = kind
    }

    // DownloadEngine

    func add(_ task: DownloadTask) async {
        lock.lock(); _added.append(task.id); lock.unlock()
    }

    func pause(_ id: DownloadTask.ID) async {
        lock.lock(); _paused.append(id); lock.unlock()
    }

    func resume(_ id: DownloadTask.ID) async {
        lock.lock(); _resumed.append(id); lock.unlock()
    }

    func remove(_ id: DownloadTask.ID, deleteData: Bool) async {
        lock.lock()
        _removed.append(id)
        let continuation = continuations[id]
        continuations[id] = nil
        buffered[id] = nil
        lock.unlock()
        continuation?.finish()
    }

    func applyLimits(_ profile: TrafficProfile) async {
        lock.lock(); _applyLimits.append(profile); lock.unlock()
    }

    func setFilePriority(_ priority: FilePriority, fileID: Int, task id: DownloadTask.ID) async {
        lock.lock(); _filePriorities.append((priority, fileID, id)); lock.unlock()
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

    // Test driving / inspection

    /// Emit an event for a task; buffered until a subscriber attaches.
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

    var added: [UUID] { lock.lock(); defer { lock.unlock() }; return _added }
    var resumed: [UUID] { lock.lock(); defer { lock.unlock() }; return _resumed }
    var paused: [UUID] { lock.lock(); defer { lock.unlock() }; return _paused }
    var removed: [UUID] { lock.lock(); defer { lock.unlock() }; return _removed }
    var applyLimitsCalls: [TrafficProfile] { lock.lock(); defer { lock.unlock() }; return _applyLimits }
    var filePriorities: [(FilePriority, Int, UUID)] { lock.lock(); defer { lock.unlock() }; return _filePriorities }
}

// MARK: - Tests

final class DownloadManagerTests: XCTestCase {

    private let saveDir = NSTemporaryDirectory()

    // MARK: Helpers

    private func urlSource(_ s: String) -> DownloadSource {
        .url(URL(string: s)!)
    }

    private func magnetSource(_ hash: String) -> DownloadSource {
        .magnet("magnet:?xt=urn:btih:\(hash)&dn=Demo+Pack")
    }

    /// A profile identical to `.medium` but with overridable queue caps.
    private func profile(
        maxSimultaneousDownloads: Int,
        maxMetadataResolutions: Int = 99
    ) -> TrafficProfile {
        TrafficProfile(
            name: "Test",
            maxDownloadBytesPerSec: 5 * 1024 * 1024,
            maxUploadBytesPerSec: 1 * 1024 * 1024,
            maxConnections: 100,
            maxConnectionsPerServer: 8,
            maxSimultaneousDownloads: maxSimultaneousDownloads,
            maxMetadataResolutions: maxMetadataResolutions,
            seedRatioLimit: 1.0,
            enableExtraConnections: true
        )
    }

    private func settings(_ profile: TrafficProfile, speedLimitEnabled: Bool = true) -> AppSettings {
        AppSettings(
            profiles: [profile] + TrafficProfile.defaults,
            selectedProfileName: profile.name,
            speedLimitEnabled: speedLimitEnabled,
            defaultSaveDirectory: saveDir
        )
    }

    /// Poll an actor-isolated predicate until it holds or the timeout fires.
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

    private func count(_ manager: DownloadManager, status: DownloadStatus) async -> Int {
        await manager.snapshot.filter { $0.status == status }.count
    }

    // MARK: (a) Routing — a task is added and routed to the correct engine

    func testAddRoutesToCorrectEngineAndAppears() async throws {
        let http = FakeEngine(kind: .http)
        let torrent = FakeEngine(kind: .torrent)
        let manager = DownloadManager(
            httpEngine: http,
            torrentEngine: torrent,
            settings: settings(profile(maxSimultaneousDownloads: 5))
        )

        let httpTask = await manager.add(source: urlSource("https://example.test/file.bin"))
        let torrentTask = await manager.add(source: magnetSource("aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111"))

        // Both tasks appear in the unified list.
        let ids = await manager.snapshot.map(\.id)
        XCTAssertEqual(Set(ids), Set([httpTask.id, torrentTask.id]))

        // Each was handed to exactly the right engine.
        let httpRouted = await waitUntil { http.added == [httpTask.id] }
        let torrentRouted = await waitUntil { torrent.added == [torrentTask.id] }
        XCTAssertTrue(httpRouted)
        XCTAssertTrue(torrentRouted)
        XCTAssertTrue(http.added.contains(httpTask.id))
        XCTAssertFalse(http.added.contains(torrentTask.id))
        XCTAssertTrue(torrent.added.contains(torrentTask.id))
        XCTAssertFalse(torrent.added.contains(httpTask.id))

        // Name derivation: HTTP from the path, magnet from the dn= parameter.
        XCTAssertEqual(httpTask.name, "file.bin")
        XCTAssertEqual(torrentTask.name, "Demo Pack")
    }

    // MARK: (b) Duplicate sources are rejected

    func testDuplicateSourceIsRejected() async throws {
        let http = FakeEngine(kind: .http)
        let torrent = FakeEngine(kind: .torrent)
        let manager = DownloadManager(
            httpEngine: http,
            torrentEngine: torrent,
            settings: settings(profile(maxSimultaneousDownloads: 5))
        )

        let first = await manager.add(source: urlSource("https://example.test/dup.bin"))
        let second = await manager.add(source: urlSource("https://example.test/dup.bin"))

        XCTAssertEqual(first.id, second.id, "the same locator must resolve to the existing task")
        let all = await manager.snapshot
        XCTAssertEqual(all.count, 1, "no duplicate task should be created")
    }

    // MARK: (c) The simultaneous-download cap is respected

    func testSimultaneousDownloadCapIsRespected() async throws {
        let http = FakeEngine(kind: .http)
        let torrent = FakeEngine(kind: .torrent)
        let cap = 2
        let manager = DownloadManager(
            httpEngine: http,
            torrentEngine: torrent,
            settings: settings(profile(maxSimultaneousDownloads: cap))
        )

        for i in 0..<5 {
            _ = await manager.add(source: urlSource("https://example.test/f\(i).bin"))
        }

        // Exactly `cap` downloading, the remainder queued.
        let reached = await waitUntil {
            await self.count(manager, status: .downloading) == cap
        }
        XCTAssertTrue(reached)
        let downloading = await count(manager, status: .downloading)
        let queued = await count(manager, status: .queued)
        XCTAssertEqual(downloading, cap)
        XCTAssertEqual(queued, 5 - cap)

        // Only `cap` tasks were ever handed to the engine.
        XCTAssertEqual(http.added.count, cap)
    }

    // MARK: (d) Completing/seeding a task promotes a queued one

    func testCompletionPromotesQueuedTask() async throws {
        let http = FakeEngine(kind: .http)
        let torrent = FakeEngine(kind: .torrent)
        let manager = DownloadManager(
            httpEngine: http,
            torrentEngine: torrent,
            settings: settings(profile(maxSimultaneousDownloads: 1))
        )

        let a = await manager.add(source: urlSource("https://example.test/a.bin"))
        let b = await manager.add(source: urlSource("https://example.test/b.bin"))

        // Only the first runs; the second waits.
        let firstStarted = await waitUntil { http.added == [a.id] }
        XCTAssertTrue(firstStarted)
        let bQueued = await manager.task(b.id)?.status
        XCTAssertEqual(bQueued, .queued)

        // Finish the first; its slot frees and the second is promoted.
        http.emit(.statusChanged(.completed), for: a.id)

        let secondStarted = await waitUntil { http.added.contains(b.id) }
        XCTAssertTrue(secondStarted)
        let aStatus = await manager.task(a.id)?.status
        let bStatus = await manager.task(b.id)?.status
        XCTAssertEqual(aStatus, .completed)
        XCTAssertEqual(bStatus, .downloading)
    }

    // MARK: (d') Seeding (not only completion) also frees a slot

    func testSeedingFreesSlotAndPromotes() async throws {
        let http = FakeEngine(kind: .http)
        let torrent = FakeEngine(kind: .torrent)
        let manager = DownloadManager(
            httpEngine: http,
            torrentEngine: torrent,
            settings: settings(profile(maxSimultaneousDownloads: 1))
        )

        let a = await manager.add(source: magnetSource("1111111111111111111111111111111111111111"))
        let b = await manager.add(source: magnetSource("2222222222222222222222222222222222222222"))

        let firstStarted = await waitUntil { torrent.added == [a.id] }
        XCTAssertTrue(firstStarted)
        let bQueued = await manager.task(b.id)?.status
        XCTAssertEqual(bQueued, .queued)

        // First torrent reaches seeding — slot frees even though it's still active.
        torrent.emit(.statusChanged(.seeding), for: a.id)

        let secondStarted = await waitUntil { torrent.added.contains(b.id) }
        XCTAssertTrue(secondStarted)
        let aStatus = await manager.task(a.id)?.status
        let bStatus = await manager.task(b.id)?.status
        XCTAssertEqual(aStatus, .seeding)
        // A magnet that has just been promoted is resolving metadata (an active,
        // slot-occupying phase) — the point is it was promoted off the queue.
        XCTAssertEqual(bStatus, .requestingMetadata)
    }

    // MARK: (e) Switching profile / toggling the snail re-applies limits

    func testProfileSwitchAndSnailReapplyLimits() async throws {
        let http = FakeEngine(kind: .http)
        let torrent = FakeEngine(kind: .torrent)
        let manager = DownloadManager(
            httpEngine: http,
            torrentEngine: torrent,
            settings: settings(profile(maxSimultaneousDownloads: 5))
        )

        // Switching profile applies the new limits to BOTH engines.
        await manager.setProfile("Low")
        XCTAssertEqual(http.applyLimitsCalls.last?.name, "Low")
        XCTAssertEqual(torrent.applyLimitsCalls.last?.name, "Low")
        XCTAssertGreaterThan(http.applyLimitsCalls.last?.maxDownloadBytesPerSec ?? 0, 0)

        // Turning the snail OFF lifts the byte caps (unlimited) on both engines.
        await manager.setSpeedLimitEnabled(false)
        XCTAssertEqual(http.applyLimitsCalls.last?.maxDownloadBytesPerSec, 0)
        XCTAssertEqual(http.applyLimitsCalls.last?.maxUploadBytesPerSec, 0)
        XCTAssertEqual(torrent.applyLimitsCalls.last?.maxDownloadBytesPerSec, 0)

        // Turning it back ON restores the selected profile's caps.
        await manager.setSpeedLimitEnabled(true)
        XCTAssertEqual(http.applyLimitsCalls.last?.maxDownloadBytesPerSec, TrafficProfile.low.maxDownloadBytesPerSec)
    }

    func testApplyReturnsCommittedSettingsAndReachesEngine() async {
        let http = FakeEngine(kind: .http)
        let torrent = FakeEngine(kind: .torrent)
        let manager = DownloadManager(
            httpEngine: http,
            torrentEngine: torrent,
            settings: settings(profile(maxSimultaneousDownloads: 5))
        )

        // The deep apply() commits the change AND returns the stored result, so a
        // caller never needs a separate read-after-write to learn what was saved…
        let committed = await manager.apply { $0.selectedProfileName = "Low" }
        XCTAssertEqual(committed.selectedProfileName, "Low")
        // …and the same change cascaded down to BOTH engines via applyLimits.
        XCTAssertEqual(http.applyLimitsCalls.last?.name, "Low")
        XCTAssertEqual(torrent.applyLimitsCalls.last?.name, "Low")
    }

    func testApplySnailOffSendsZeroCapsToEngine() async {
        let http = FakeEngine(kind: .http)
        let torrent = FakeEngine(kind: .torrent)
        let manager = DownloadManager(
            httpEngine: http,
            torrentEngine: torrent,
            settings: settings(profile(maxSimultaneousDownloads: 5))
        )

        // Disabling the speed limit through apply() reports unlimited (0) caps on
        // the committed settings and pushes those same zero caps to the engines.
        let committed = await manager.apply { $0.speedLimitEnabled = false }
        XCTAssertFalse(committed.speedLimitEnabled)
        XCTAssertEqual(committed.effectiveProfile.maxDownloadBytesPerSec, 0)
        XCTAssertEqual(http.applyLimitsCalls.last?.maxDownloadBytesPerSec, 0)
        XCTAssertEqual(http.applyLimitsCalls.last?.maxUploadBytesPerSec, 0)
        XCTAssertEqual(torrent.applyLimitsCalls.last?.maxDownloadBytesPerSec, 0)
    }

    // MARK: (f) Engine events update the stored task

    func testEngineEventsUpdateStoredTask() async throws {
        let http = FakeEngine(kind: .http)
        let torrent = FakeEngine(kind: .torrent)
        let manager = DownloadManager(
            httpEngine: http,
            torrentEngine: torrent,
            settings: settings(profile(maxSimultaneousDownloads: 5))
        )

        let task = await manager.add(source: urlSource("https://example.test/big.bin"))
        let started = await waitUntil { http.added.contains(task.id) }
        XCTAssertTrue(started)

        // Metadata, progress and a file update flow in from the engine.
        http.emit(.metadataResolved(
            name: "big.bin",
            totalBytes: 1000,
            files: [TransferFile(id: 0, path: "big.bin", length: 1000)]
        ), for: task.id)
        http.emit(.progress(
            bytesDownloaded: 400,
            bytesUploaded: 0,
            downloadSpeed: 200,
            uploadSpeed: 0,
            connectionCount: 4
        ), for: task.id)
        http.emit(.fileProgress(fileID: 0, bytesCompleted: 400), for: task.id)

        // Wait on the file update (the last of the three events) so all earlier
        // events are guaranteed applied before we snapshot.
        let progressed = await waitUntil {
            await manager.task(task.id)?.files.first?.bytesCompleted == 400
        }
        XCTAssertTrue(progressed)
        let snap = await manager.task(task.id)
        XCTAssertEqual(snap?.totalBytes, 1000)
        XCTAssertEqual(snap?.bytesDownloaded, 400)
        XCTAssertEqual(snap?.downloadSpeed, 200)
        XCTAssertEqual(snap?.connectionCount, 4)
        XCTAssertEqual(snap?.files.first?.bytesCompleted, 400)
        XCTAssertEqual(snap?.fractionCompleted ?? 0, 0.4, accuracy: 0.0001)

        // A terminal status flows through and stamps the completion date.
        http.emit(.statusChanged(.completed), for: task.id)
        let completed = await waitUntil {
            await manager.task(task.id)?.status == .completed
        }
        XCTAssertTrue(completed)
        let done = await manager.task(task.id)
        XCTAssertEqual(done?.status, .completed)
        XCTAssertNotNil(done?.completedAt)
    }

    // MARK: Pause / resume against a real engine (integration)

    func testPauseAndResumeWithMockTorrentEngine() async throws {
        let http = FakeEngine(kind: .http)
        let sim = MockTorrentEngine.Simulation(
            tickInterval: 0.01,
            bytesPerTick: 1 * 1024 * 1024,
            uploadBytesPerTick: 0,
            metadataDelayTicks: 0,
            minPeers: 1,
            maxPeers: 4
        )
        let torrent = MockTorrentEngine(simulation: sim, profile: .high)
        let manager = DownloadManager(
            httpEngine: http,
            torrentEngine: torrent,
            settings: settings(profile(maxSimultaneousDownloads: 2))
        )

        let task = await manager.add(source: magnetSource("3333333333333333333333333333333333333333"))

        // It starts downloading via the real engine.
        let downloading = await waitUntil {
            await manager.task(task.id)?.status == .downloading
        }
        XCTAssertTrue(downloading)

        await manager.pause(task.id)
        let paused = await manager.task(task.id)?.status
        XCTAssertEqual(paused, .paused)

        // Resume puts it back to work.
        await manager.resume(task.id)
        let resumed = await waitUntil(timeout: 10) {
            let s = await manager.task(task.id)?.status
            return s == .downloading || s == .seeding || s == .completed
        }
        XCTAssertTrue(resumed)

        await manager.remove(task.id, deleteData: true)
        let removed = await manager.task(task.id)
        XCTAssertNil(removed)
    }
}
