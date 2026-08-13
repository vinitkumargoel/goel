import XCTest
@testable import GoelCore

/// A relay reserves both halves up front, then opens a transfer channel against each reservation.
/// Leaving the spent unit in `reserved` while the new channel was also counted billed one connection
/// as two, so a pool of 8 admitted only 4 — three same-server transfers then queued invisibly behind
/// a cap that looked wide open.
///
/// `SFTPSessionPool` is an actor and its counters are private, so every assertion here is behavioural:
/// a request that fits the cap is admitted at once, one that does not stays queued. `SFTPSessionChannel`
/// only opens its connection on the first job, so building channels here touches no network.
final class SFTPSessionPoolReservationTests: XCTestCase {

    private let target = SFTPTarget(host: "pool.invalid", port: 22, username: "vinit", password: nil)
    private let firstLeg = UUID()
    private let secondLeg = UUID()

    /// Long enough that a healthy admission is never mistaken for a blocked one on a loaded CI box.
    private let admissionTimeout: TimeInterval = 5
    /// Only paid by assertions that expect a block, so it is kept as short as it can be while still
    /// giving the reserving task time to reach the pool.
    private let blockedTimeout: TimeInterval = 0.3

    private final class Latch: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return flag }
        func set() { lock.lock(); flag = true; lock.unlock() }
    }

    /// A reservation that does not fit suspends forever, so it cannot simply be awaited. Runs it off to
    /// the side and reports whether it was admitted; the caller drains the pool afterwards so a blocked
    /// task is resumed rather than abandoned mid-continuation.
    private func probeReserve(_ pool: SFTPSessionPool, count: Int, timeout: TimeInterval,
                              file: StaticString = #filePath,
                              line: UInt = #line) async -> (admitted: Bool, task: Task<Void, Never>) {
        let started = Latch()
        let latch = Latch()
        let target = self.target
        let task = Task {
            started.set()
            await pool.reserve(target, count: count)
            latch.set()
        }
        // A probe that was never scheduled would read as "correctly blocked", quietly turning every
        // negative assertion below into a no-op. Wait for the task to actually reach the pool first.
        let startDeadline = Date().addingTimeInterval(5)
        while !started.isSet, Date() < startDeadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(started.isSet, "the reservation probe never started", file: file, line: line)

        let deadline = Date().addingTimeInterval(timeout)
        while !latch.isSet, Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return (latch.isSet, task)
    }

    /// `shutdownAll` resumes every queued waiter, which is what lets a deliberately-blocked probe finish.
    private func drain(_ pool: SFTPSessionPool, _ task: Task<Void, Never>) async {
        await pool.shutdownAll()
        await task.value
    }

    /// One relay: two slots reserved up front, one transfer channel opened against each.
    private func relayHoldingTwoChannels(cap: Int = 4) async -> SFTPSessionPool {
        let pool = SFTPSessionPool(maxPerServer: cap)
        await pool.reserve(target, count: 2)
        _ = await pool.channel(for: target, role: .transfer(firstLeg), expected: nil)
        _ = await pool.channel(for: target, role: .transfer(secondLeg), expected: nil)
        return pool
    }

    func testTwoChannelsOpenedAgainstTwoReservationsConsumeTwoSlotsNotFour() async {
        let pool = await relayHoldingTwoChannels(cap: 4)

        // The relay holds exactly 2 of 4. A second relay must therefore still fit — under the
        // double-count it saw 4 of 4 and queued behind a cap that was only half spent.
        let probe = await probeReserve(pool, count: 2, timeout: admissionTimeout)

        XCTAssertTrue(probe.admitted,
                      "a relay holding 2 slots was billed for 4: the pool's effective concurrency is half its documented cap")
        await drain(pool, probe.task)
    }

    func testChannelsOpenedAgainstAReservationStillCountAgainstTheCap() async {
        let pool = await relayHoldingTwoChannels(cap: 4)

        // The other side of the same accounting: spending the reservation must hand the slot to the
        // channel, not release it. Asking for 3 more of 4 must not be admitted.
        let probe = await probeReserve(pool, count: 3, timeout: blockedTimeout)

        XCTAssertFalse(probe.admitted,
                       "the reservation was released instead of being spent on the channel — the pool now admits 5 connections against a cap of 4")
        await drain(pool, probe.task)
    }

    func testClosingABorrowedChannelReturnsItsSlotToTheOwnerNotToThePool() async {
        // The relay still owes `release(count: 2)`; closing one of its channels early must hand that
        // unit back to `reserved` rather than free it, or the owner's release frees it a second time.
        func relayAfterOneChannelClosedEarly() async -> SFTPSessionPool {
            let pool = await relayHoldingTwoChannels(cap: 4)
            await pool.releaseTransfer(firstLeg, target: target)
            return pool
        }

        // Not double-freed: usage is still 2, so 3 more do not fit.
        let notFreedTwice = await relayAfterOneChannelClosedEarly()
        let overCap = await probeReserve(notFreedTwice, count: 3, timeout: blockedTimeout)
        XCTAssertFalse(overCap.admitted,
                       "closing a borrowed channel freed a slot its owner had not released yet — the pool lets a 5th connection past a cap of 4")
        await drain(notFreedTwice, overCap.task)

        // Not leaked either: usage is still exactly 2, so 2 more do fit.
        let notLeaked = await relayAfterOneChannelClosedEarly()
        let atCap = await probeReserve(notLeaked, count: 2, timeout: admissionTimeout)
        XCTAssertTrue(atCap.admitted,
                      "closing a borrowed channel left its unit charged twice — the freed slot is now unreachable for the rest of the session")
        await drain(notLeaked, atCap.task)

        // And the whole relay unwinds cleanly: the owner's release plus the surviving channel's close
        // must hand back everything, leaving the full cap available again.
        let unwound = await relayAfterOneChannelClosedEarly()
        await unwound.release(target, count: 2)
        await unwound.releaseTransfer(secondLeg, target: target)
        let fullCap = await probeReserve(unwound, count: 4, timeout: admissionTimeout)
        XCTAssertTrue(fullCap.admitted,
                      "a fully unwound relay left slots behind: every relay that runs shrinks the pool for the next one")
        await drain(unwound, fullCap.task)
    }
}
