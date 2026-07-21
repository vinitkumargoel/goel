import XCTest
@testable import GoelCore

/// Pure unit tests for ``ConnectionBudget`` — reserve/release accounting and
/// segment-count resolution against a traffic profile. No network / actor.
final class ConnectionBudgetTests: XCTestCase {

    // MARK: Reserve / release

    func testReserveAndReleaseTracksGlobalAndHost() {
        var budget = ConnectionBudget()
        budget.reserve(host: "a.example", count: 4)
        budget.reserve(host: "b.example", count: 2)
        XCTAssertEqual(budget.totalConnections, 6)
        XCTAssertEqual(budget.hostInUse("a.example"), 4)
        XCTAssertEqual(budget.hostInUse("b.example"), 2)

        budget.release(host: "a.example", count: 4)
        XCTAssertEqual(budget.totalConnections, 2)
        XCTAssertEqual(budget.hostInUse("a.example"), 0)
        XCTAssertNil(budget.connectionsByHost["a.example"], "zero host entries drop")

        budget.release(host: "b.example", count: 2)
        XCTAssertEqual(budget.totalConnections, 0)
        XCTAssertTrue(budget.connectionsByHost.isEmpty)
    }

    func testReleaseNeverGoesNegative() {
        var budget = ConnectionBudget()
        budget.reserve(host: "h", count: 1)
        budget.release(host: "h", count: 5)
        XCTAssertEqual(budget.totalConnections, 0)
        XCTAssertEqual(budget.hostInUse("h"), 0)
    }

    func testZeroCountIsNoOp() {
        var budget = ConnectionBudget()
        budget.reserve(host: "h", count: 0)
        budget.release(host: nil, count: 0)
        XCTAssertEqual(budget.totalConnections, 0)
        XCTAssertTrue(budget.connectionsByHost.isEmpty)
    }

    func testNilHostSkipsPerHostMap() {
        var budget = ConnectionBudget()
        budget.reserve(host: nil, count: 3)
        XCTAssertEqual(budget.totalConnections, 3)
        XCTAssertTrue(budget.connectionsByHost.isEmpty)
        budget.release(host: nil, count: 3)
        XCTAssertEqual(budget.totalConnections, 0)
    }

    // MARK: Room

    func testHostAndGlobalRoomFloorAtOne() {
        var budget = ConnectionBudget()
        budget.reserve(host: "h", count: 16)
        // Over capacity: room still floors at 1 so a new download never stalls.
        XCTAssertEqual(budget.hostRoom(host: "h", maxPerServer: 8), 1)
        XCTAssertEqual(budget.globalRoom(maxConnections: 10), 1)
    }

    // MARK: resolveSegmentCount

    func testLowProfileAlwaysOneSegment() {
        let budget = ConnectionBudget()
        let n = budget.resolveSegmentCount(total: 100 * 1024 * 1024, host: "h", profile: .low)
        XCTAssertEqual(n, 1)
    }

    func testHighProfileUsesPerServerCapWhenRoomFree() {
        let budget = ConnectionBudget()
        // High: maxConnectionsPerServer = 16, plenty of global room, large file.
        let n = budget.resolveSegmentCount(total: 100 * 1024 * 1024, host: "h", profile: .high)
        XCTAssertEqual(n, 16)
    }

    func testSegmentCountRespectsHostBudgetAlreadyInUse() {
        var budget = ConnectionBudget()
        budget.reserve(host: "h", count: 12)
        // High per-server = 16 → room 4.
        let n = budget.resolveSegmentCount(total: 100 * 1024 * 1024, host: "h", profile: .high)
        XCTAssertEqual(n, 4)
    }

    func testSegmentCountRespectsGlobalBudget() {
        var budget = ConnectionBudget()
        // Medium: maxConnections = 200, per-server = 8. Fill global nearly full.
        budget.reserve(host: "other", count: 198)
        let n = budget.resolveSegmentCount(total: 100 * 1024 * 1024, host: "h", profile: .medium)
        // global room = max(1, 200-198) = 2; per-server free = 8 → min = 2
        XCTAssertEqual(n, 2)
    }

    func testSegmentCountClampsByFileSize() {
        let budget = ConnectionBudget()
        // 100 KiB / 64 KiB floor → at most 2 segments even on High (16).
        let n = budget.resolveSegmentCount(total: 100 * 1024, host: "h", profile: .high)
        XCTAssertEqual(n, 2)
    }

    func testSegmentCountFloorOneWhenBudgetsExhausted() {
        var budget = ConnectionBudget()
        budget.reserve(host: "h", count: 500)
        let n = budget.resolveSegmentCount(total: 100 * 1024 * 1024, host: "h", profile: .high)
        XCTAssertEqual(n, 1, "never zero connections")
    }
}
