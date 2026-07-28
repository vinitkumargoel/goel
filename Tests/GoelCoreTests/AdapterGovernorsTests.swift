import XCTest
@testable import GoelCore

/// Unit tests for ``AdapterGovernors``, the per-adapter limiters for multi-path segmented downloads:
/// a 429 on one NIC's source IP shrinks only that adapter's ceiling; siblings keep their fan-out.
final class AdapterGovernorsTests: XCTestCase {

    // MARK: Helpers

    /// Cross-task completion flag; NSLock because the observing side polls from
    /// the test task while the setting side runs on an arbitrary executor.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func makeGovernors(limit: Int) -> AdapterGovernors {
        AdapterGovernors(adapters: [
            BoundAdapter(bsdName: "en0", displayName: "Wi-Fi"),
            BoundAdapter(bsdName: "en1", displayName: "Ethernet"),
        ], limit: limit)
    }

    /// Runs `body` in a child task and reports whether it finished within `timeout` — a parked
    /// acquire must surface as a test failure, never as a suite-wide hang.
    private func completes(within timeout: TimeInterval = 2,
                           _ body: @escaping @Sendable () async throws -> Void) async -> Bool {
        let done = Flag()
        let task = Task { try await body(); done.set() }
        let deadline = Date().addingTimeInterval(timeout)
        while !done.isSet, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        task.cancel()
        return done.isSet
    }

    /// Polls `flag` until set or `timeout` elapses.
    private func wait(for flag: Flag, timeout: TimeInterval = 2) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !flag.isSet, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return flag.isSet
    }

    // MARK: Wide open at start

    func testStartsWideOpenAdmitsFullFanOutPerAdapter() async {
        // limit = ranges.count: every adapter must admit the full fan-out
        // without parking — the behavior-identical-until-the-first-429 guarantee.
        let governors = makeGovernors(limit: 3)
        let admitted = await completes {
            for _ in 0..<3 { try await governors.acquire("en0") }
            for _ in 0..<3 { try await governors.acquire("en1") }
        }
        XCTAssertTrue(admitted, "full fan-out on each adapter must be admitted immediately")
    }

    func testDuplicateAdapterEntriesShareOneGovernor() async {
        // The plan can list the same NIC twice (round-robin over a short adapter
        // list); the keyed map must dedupe so the pair shares one ceiling.
        let governors = AdapterGovernors(adapters: [
            BoundAdapter(bsdName: "en0", displayName: "Wi-Fi"),
            BoundAdapter(bsdName: "en0", displayName: "Wi-Fi"),
        ], limit: 1)
        let first = await completes { try await governors.acquire("en0") }
        XCTAssertTrue(first)

        let parked = Flag()
        let waiter = Task { try await governors.acquire("en0"); parked.set() }
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(parked.isSet, "one shared governor: the second acquire must park")
        waiter.cancel()
        _ = try? await waiter.value
    }

    // MARK: Throttle isolation

    func testThrottleDownShrinksOnlyTheTargetAdapter() async throws {
        let governors = makeGovernors(limit: 2)
        await governors.throttleDown("en0")           // en0 ceiling 2 → 1
        try await governors.acquire("en0")            // fills en0

        let parked = Flag()
        let waiter = Task { try await governors.acquire("en0"); parked.set() }
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(parked.isSet, "en0 was throttled to 1: the second acquire must park")

        // The sibling adapter is untouched by en0's 429.
        let siblingOpen = await completes {
            try await governors.acquire("en1")
            try await governors.acquire("en1")
        }
        XCTAssertTrue(siblingOpen, "en1 must keep its full fan-out after en0's throttle")

        // A release admits the parked waiter — acquire/release stays balanced.
        await governors.release("en0")
        let admitted = await wait(for: parked)
        XCTAssertTrue(admitted, "releasing en0's slot must admit the parked waiter")
        _ = try? await waiter.value
    }

    // MARK: Cancellation

    func testAcquireCancellationDequeuesParkedWaiter() async throws {
        let governors = makeGovernors(limit: 1)
        try await governors.acquire("en0")            // fill the only slot

        let threwCancellation = Flag()
        let granted = Flag()
        let waiter = Task {
            do { try await governors.acquire("en0"); granted.set() }
            catch is CancellationError { threwCancellation.set() }
            catch {}
        }
        try? await Task.sleep(nanoseconds: 200_000_000)   // let it park
        waiter.cancel()
        _ = await waiter.value
        XCTAssertTrue(threwCancellation.isSet, "a cancelled parked waiter must throw CancellationError")
        XCTAssertFalse(granted.isSet, "a cancelled waiter must never be granted a slot")

        // Slot accounting is intact: the held slot releases, and a fresh acquire
        // succeeds immediately (no leaked reservation from the cancelled waiter).
        await governors.release("en0")
        let reacquired = await completes { try await governors.acquire("en0") }
        XCTAssertTrue(reacquired, "release + acquire must succeed after a cancelled waiter")
    }

    // MARK: Unknown keys

    func testUnknownAdapterKeyIsNoOp() async {
        let governors = makeGovernors(limit: 1)
        let finished = await completes {
            // Repeated acquires beyond any limit prove no slot is tracked for an
            // unknown key — bookkeeping must never deadlock a pump.
            for _ in 0..<5 { try await governors.acquire("utun9") }
            await governors.release("utun9")
            await governors.throttleDown("utun9")
        }
        XCTAssertTrue(finished, "unknown adapter keys must be no-ops, never traps or hangs")
    }
}
