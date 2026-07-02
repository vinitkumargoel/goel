import XCTest
@testable import GoelCore

/// Direct tests for the progress re-base ledger extracted from
/// `DownloadManager.apply(.progress)` into ``StatsAccumulator`` — the subtle
/// regression rule that fires ~10×/sec/task and previously had no isolated
/// coverage (it was only reachable by pushing crafted event streams through the
/// whole actor).
final class StatsAccumulatorTests: XCTestCase {
    private typealias Mark = StatsAccumulator.Mark

    func testMonotonicProgressCountsEachIntervalOnce() {
        var r = StatsAccumulator.fold(previous: Mark(down: 0, up: 0), absoluteDown: 100, absoluteUp: 10)
        XCTAssertEqual(r.deltaDown, 100)
        XCTAssertEqual(r.deltaUp, 10)
        XCTAssertEqual(r.newMark, Mark(down: 100, up: 10))

        r = StatsAccumulator.fold(previous: r.newMark, absoluteDown: 250, absoluteUp: 30)
        XCTAssertEqual(r.deltaDown, 150, "only the new interval, not the absolute total")
        XCTAssertEqual(r.deltaUp, 20)
    }

    func testRegressionRebasesAndNeverSubtractsHistory() {
        // Progressed to 500 down / 100 up, then a retry restarts the engine's
        // absolute count far below the mark.
        let r = StatsAccumulator.fold(previous: Mark(down: 500, up: 100), absoluteDown: 40, absoluteUp: 5)
        XCTAssertEqual(r.deltaDown, 0, "a regressed reading contributes no negative delta")
        XCTAssertEqual(r.deltaUp, 0)
        XCTAssertEqual(r.newMark, Mark(down: 40, up: 5), "the mark re-bases down to the new absolute")
    }

    func testReTransferredBytesAfterRebaseCountAgain() {
        // After re-basing to 40, climbing back to 120 records the re-transferred
        // interval (120 − 40 = 80), not the full 120 nor a negative jump.
        let rebased = StatsAccumulator.fold(previous: Mark(down: 500, up: 0), absoluteDown: 40, absoluteUp: 0)
        let r = StatsAccumulator.fold(previous: rebased.newMark, absoluteDown: 120, absoluteUp: 0)
        XCTAssertEqual(r.deltaDown, 80)
    }

    func testStartBelowPreviousThenForwardProgress() {
        // Mark at 300; a first reading of 100 (below) re-bases to 100 with 0 delta;
        // then 350 records 250 forward.
        let rebased = StatsAccumulator.fold(previous: Mark(down: 300, up: 0), absoluteDown: 100, absoluteUp: 0)
        XCTAssertEqual(rebased.deltaDown, 0)
        let r = StatsAccumulator.fold(previous: rebased.newMark, absoluteDown: 350, absoluteUp: 0)
        XCTAssertEqual(r.deltaDown, 250)
    }

    func testDownAndUpRebaseIndependently() {
        // Down regresses while up keeps climbing — each axis is handled on its own.
        let r = StatsAccumulator.fold(previous: Mark(down: 500, up: 100), absoluteDown: 40, absoluteUp: 160)
        XCTAssertEqual(r.deltaDown, 0, "down regressed → 0")
        XCTAssertEqual(r.deltaUp, 60, "up advanced 100→160 → 60")
        XCTAssertEqual(r.newMark, Mark(down: 40, up: 160))
    }
}
