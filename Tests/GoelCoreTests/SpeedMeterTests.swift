import XCTest
@testable import GoelCore

/// ``SpeedMeter`` — the sliding-window average behind every displayed transfer
/// rate. All tests drive the injected clock, so the window math is exercised
/// deterministically.
final class SpeedMeterTests: XCTestCase {

    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    // MARK: Window math

    func testSteadyStreamReadsExactRate() {
        var meter = SpeedMeter()
        // 100 kB every 0.5 s = 200 kB/s, sampled for 5 s.
        for i in 0...10 {
            meter.record(down: Int64(i) * 100_000, at: at(Double(i) * 0.5))
        }
        XCTAssertEqual(meter.reading(at: at(5)).down, 200_000, accuracy: 1)
    }

    func testBurstyCountersAverageFlat() {
        // Bytes arrive in alternating half-second ticks — a 200 kB burst, then
        // nothing. The instantaneous rate swings between 0 and 400 kB/s; the
        // window average holds the true mean of 200 kB/s.
        var meter = SpeedMeter()
        var total: Int64 = 0
        for i in 0...12 {
            if i.isMultiple(of: 2) == false { total += 200_000 }
            meter.record(down: total, at: at(Double(i) * 0.5))
        }
        XCTAssertEqual(meter.reading(at: at(6)).down, 200_000, accuracy: 1)
    }

    func testWindowSlidesToTrackARateChange() {
        var meter = SpeedMeter()
        // 3 s at 1 MB/s…
        var total: Int64 = 0
        for i in 0...6 {
            total = Int64(i) * 500_000
            meter.record(down: total, at: at(Double(i) * 0.5))
        }
        XCTAssertEqual(meter.reading(at: at(3)).down, 1_000_000, accuracy: 10_000)
        // …then 3 s at 100 kB/s: once the fast phase slides out of the window,
        // the reading settles on the new rate.
        for i in 1...6 {
            meter.record(down: total + Int64(i) * 50_000, at: at(3 + Double(i) * 0.5))
        }
        XCTAssertEqual(meter.reading(at: at(6)).down, 100_000, accuracy: 10_000)
    }

    func testBothChannelsAverageIndependently() {
        var meter = SpeedMeter()
        for i in 0...6 {
            meter.record(down: Int64(i) * 100_000, up: Int64(i) * 25_000, at: at(Double(i) * 0.5))
        }
        let reading = meter.reading(at: at(3))
        XCTAssertEqual(reading.down, 200_000, accuracy: 1)
        XCTAssertEqual(reading.up, 50_000, accuracy: 1)
    }

    // MARK: Ramp-in and empty states

    func testEmptyMeterReadsZero() {
        XCTAssertEqual(SpeedMeter().reading(at: t0), .zero)
    }

    func testReportsZeroUntilMinimumSpan() {
        var meter = SpeedMeter()
        meter.record(down: 0, at: t0)
        meter.record(down: 500_000, at: at(0.1))
        // 0.1 s of history: a burst, not a rate — no headline extrapolation.
        XCTAssertEqual(meter.reading(at: at(0.1)).down, 0)
        // Once the minimum span has elapsed the growing window reports.
        meter.record(down: 600_000, at: at(0.6))
        XCTAssertEqual(meter.reading(at: at(0.6)).down, 1_000_000, accuracy: 1)
    }

    // MARK: Resets

    func testCounterRegressionResetsWindow() {
        var meter = SpeedMeter()
        meter.record(down: 1_000_000, at: t0)
        meter.record(down: 2_000_000, at: at(1))
        // The transfer restarted below its previous count: fresh window, and
        // the rate never reads negative.
        meter.record(down: 100_000, at: at(2))
        XCTAssertEqual(meter.reading(at: at(2)), .zero)
        meter.record(down: 200_000, at: at(3))
        XCTAssertEqual(meter.reading(at: at(3)).down, 100_000, accuracy: 1)
    }

    func testClockRewindResetsWindow() {
        var meter = SpeedMeter()
        meter.record(down: 100_000, at: at(10))
        meter.record(down: 200_000, at: at(11))
        // Wall clock jumped backwards: never report a nonsense rate.
        meter.record(down: 300_000, at: at(5))
        XCTAssertEqual(meter.reading(at: at(5)), .zero)
    }

    // MARK: Stalls

    func testStalledReadingDecaysRatherThanFreezes() {
        var meter = SpeedMeter()
        for i in 0...6 {
            meter.record(down: Int64(i) * 500_000, at: at(Double(i) * 0.5))
        }
        let live = meter.reading(at: at(3)).down
        XCTAssertEqual(live, 1_000_000, accuracy: 10_000)
        // No new bytes for a while: a poll during the stall sees the average
        // decay (the span keeps growing) instead of a frozen headline rate.
        let stalled = meter.reading(at: at(9)).down
        XCTAssertLessThan(stalled, live / 2)
    }
}
