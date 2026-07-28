import XCTest
@testable import GoelCore

final class TransferProgressMeterTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    func testAnnouncesTotalExactlyOnce() {
        var meter = TransferProgressMeter(resumeFrom: 0)
        let first = meter.step(total: 500, sofar: 10, now: t0)
        XCTAssertEqual(first.announceTotal, 500)
        let second = meter.step(total: 500, sofar: 20, now: t0.addingTimeInterval(1))
        XCTAssertNil(second.announceTotal)
    }

    func testTotalUnknownThenKnownAnnouncesWhenKnown() {
        var meter = TransferProgressMeter(resumeFrom: 0)
        XCTAssertNil(meter.step(total: 0, sofar: 10, now: t0).announceTotal)
        XCTAssertEqual(meter.step(total: 800, sofar: 20, now: t0.addingTimeInterval(1)).announceTotal, 800)
    }

    func testProgressIsThrottledToTheWindow() {
        var meter = TransferProgressMeter(resumeFrom: 0, throttle: 0.2)
        XCTAssertNotNil(meter.step(total: 0, sofar: 1, now: t0).progress)
        XCTAssertNil(meter.step(total: 0, sofar: 2, now: t0.addingTimeInterval(0.1)).progress)
        XCTAssertNotNil(meter.step(total: 0, sofar: 3, now: t0.addingTimeInterval(0.3)).progress)
    }

    func testSpeedIsWindowedOverAbsoluteOffsetAndNeverNegative() {
        var meter = TransferProgressMeter(resumeFrom: 100, throttle: 0.2)
        _ = meter.step(total: 0, sofar: 100, now: t0)
        let tick = meter.step(total: 0, sofar: 1100, now: t0.addingTimeInterval(1))
        XCTAssertEqual(tick.progress?.bytes, 1100)
        XCTAssertEqual(tick.progress?.speed ?? 0, 1000, accuracy: 0.001)
    }

    func testFirstTickReportsZeroSpeed() {
        var meter = TransferProgressMeter(resumeFrom: 0)
        XCTAssertEqual(meter.step(total: 0, sofar: 4096, now: t0).progress?.speed, 0)
    }

    func testResumeAfterDropContinuesFromOffset() {
        var run1 = TransferProgressMeter(resumeFrom: 0)
        _ = run1.step(total: 16, sofar: 8, now: t0)
        XCTAssertEqual(run1.finalBytes, 8)

        var run2 = TransferProgressMeter(resumeFrom: 8)
        _ = run2.step(total: 16, sofar: 8, now: t0)
        let done = run2.step(total: 16, sofar: 16, now: t0.addingTimeInterval(1))
        XCTAssertEqual(done.progress?.bytes, 16)
        XCTAssertEqual(run2.finalBytes, 16)
    }

    func testFinalBytesNeverBelowResumePoint() {
        var meter = TransferProgressMeter(resumeFrom: 500)
        XCTAssertEqual(meter.finalBytes, 500)
        _ = meter.step(total: 0, sofar: 400, now: t0)
        XCTAssertEqual(meter.finalBytes, 500)
    }
}
