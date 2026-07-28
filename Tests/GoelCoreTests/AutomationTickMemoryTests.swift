import XCTest
@testable import GoelCore

// MARK: - An engine whose first pause parks the caller

/// Networking-free engine whose **first** ``pause(_:)`` suspends until the test releases it, parking one
/// automation tick mid-`await` so a second interleaves — the case `runAutomation(feeds:)` must survive.
private final class GatedPauseEngine: DownloadEngine, @unchecked Sendable {

    let kind: DownloadKind

    private let lock = NSLock()
    private var continuations: [UUID: AsyncStream<EngineEvent>.Continuation] = [:]
    private var gate: CheckedContinuation<Void, Never>?
    private var pauseCalls = 0
    private var released = false
    private var entered = false

    init(kind: DownloadKind) {
        self.kind = kind
    }

    // DownloadEngine

    func add(_ task: DownloadTask) async {}

    func pause(_ id: DownloadTask.ID) async {
        lock.lock()
        pauseCalls += 1
        let block = pauseCalls == 1 && !released
        if block { entered = true }
        lock.unlock()
        guard block else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            // The test may have released between the two critical sections.
            guard !released else { lock.unlock(); continuation.resume(); return }
            gate = continuation
            lock.unlock()
        }
    }

    func resume(_ id: DownloadTask.ID) async {}

    func remove(_ id: DownloadTask.ID, deleteData: Bool) async {
        lock.lock()
        let continuation = continuations[id]
        continuations[id] = nil
        lock.unlock()
        continuation?.finish()
    }

    func applyLimits(_ profile: TrafficProfile) async {}

    func events(for id: DownloadTask.ID) -> AsyncStream<EngineEvent> {
        let (stream, continuation) = AsyncStream<EngineEvent>.makeStream(bufferingPolicy: .unbounded)
        lock.lock()
        continuations[id] = continuation
        lock.unlock()
        return stream
    }

    // Test driving / inspection

    /// True once a caller has parked inside the first ``pause(_:)``.
    var pauseEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }

    /// Let the parked caller (and every later one) through.
    func releasePause() {
        lock.lock()
        released = true
        let continuation = gate
        gate = nil
        lock.unlock()
        continuation?.resume()
    }
}

// MARK: - Tests

final class AutomationTickMemoryTests: XCTestCase {

    /// Poll an actor-isolated predicate until it holds or the timeout fires.
    private func waitUntil(timeout: TimeInterval = 5,
                           _ predicate: @escaping () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await predicate()
    }

    /// Ticks overlapping across the `await` in `pause(_:)` must not clobber each other's
    /// ``AutomationCore/Memory``: a stale write-back wipes `rssSeenKeys` or `networkPausedIDs`.
    func testOverlappingTicksPreserveBothMemoryLedgers() async throws {
        let http = GatedPauseEngine(kind: .http)
        let torrent = GatedPauseEngine(kind: .torrent)
        var settings = AppSettings(
            profiles: TrafficProfile.defaults,
            selectedProfileName: TrafficProfile.defaults[0].name,
            defaultSaveDirectory: NSTemporaryDirectory())
        settings.pauseOnExpensiveNetwork = true
        let manager = DownloadManager(httpEngine: http, torrentEngine: torrent,
                                      settings: settings)

        let task = await manager.add(source: .url(URL(string: "https://example.test/big.bin")!))
        let started = await waitUntil { await manager.task(task.id)?.status == .downloading }
        XCTAssertTrue(started)

        // Tick A: the path went metered. It decides to pause the task, records it
        // in `networkPausedIDs`, then parks inside the engine's pause.
        let tickA = Task { await manager.applyNetworkPolicy(expensive: true, constrained: false) }
        let parked = await waitUntil { http.pauseEntered }
        XCTAssertTrue(parked, "the network tick should be suspended inside pause()")

        // Tick B: an RSS poll lands mid-flight and records a feed key.
        let feedURL = "https://example.test/episode.bin"
        let source = DownloadSource.url(URL(string: feedURL)!)
        let key = "feed|\(feedURL)"
        await manager.runAutomation(feeds: [
            .init(startPaused: true,
                  candidates: [.init(key: key, source: source, dedupKey: source.dedupKey)])
        ])

        // Tick A now finishes, last.
        http.releasePause()
        await tickA.value

        let memory = await manager.automationMemory
        XCTAssertTrue(memory.rssSeenKeys.contains(key),
                      "the late-finishing network tick must not wipe the RSS ledger")
        XCTAssertEqual(memory.networkPausedIDs, [task.id],
                       "the RSS tick must not wipe the network ledger")
        XCTAssertTrue(memory.networkPaused)
    }
}
