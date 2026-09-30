import XCTest
import GoelCore
@testable import GoelApp

@MainActor
final class AutoShutdownCountdownTests: XCTestCase {

    func testNothingHappensUntilTheCountdownRunsOut() {
        var performed: [DrainIntent] = []
        let countdown = AutoShutdownCountdown(seconds: 3, autoTick: false) { performed.append($0) }
        countdown.begin(.sleep)
        XCTAssertEqual(countdown.phase, .counting(.sleep, remaining: 3))
        countdown.tick()
        countdown.tick()
        XCTAssertEqual(performed, [])
        XCTAssertEqual(countdown.phase, .counting(.sleep, remaining: 1))
        countdown.tick()
        XCTAssertEqual(performed, [.sleep])
        XCTAssertEqual(countdown.phase, .idle)
        countdown.tick()
        XCTAssertEqual(performed, [.sleep], "fires exactly once")
    }

    func testCancelStopsIt() {
        var performed: [DrainIntent] = []
        let countdown = AutoShutdownCountdown(seconds: 2, autoTick: false) { performed.append($0) }
        countdown.begin(.shutdown)
        countdown.cancel()
        countdown.tick()
        countdown.tick()
        XCTAssertEqual(performed, [])
        XCTAssertFalse(countdown.isCounting)
    }

    func testDoItNowSkipsTheWait() {
        var performed: [DrainIntent] = []
        let countdown = AutoShutdownCountdown(seconds: 60, autoTick: false) { performed.append($0) }
        countdown.begin(.quit)
        countdown.performNow()
        XCTAssertEqual(performed, [.quit])
        countdown.performNow()
        XCTAssertEqual(performed, [.quit])
    }

    func testASecondTriggerDoesNotRestartTheClock() {
        let countdown = AutoShutdownCountdown(seconds: 5, autoTick: false) { _ in }
        countdown.begin(.sleep)
        countdown.tick()
        countdown.begin(.shutdown)
        XCTAssertEqual(countdown.phase, .counting(.sleep, remaining: 4))
    }

    func testDefaultIsOneMinute() {
        XCTAssertEqual(AutoShutdownCountdown.defaultSeconds, 60)
    }
}
