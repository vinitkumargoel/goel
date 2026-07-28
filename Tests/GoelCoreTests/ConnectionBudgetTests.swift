import XCTest
@testable import GoelCore

final class ConnectionBudgetTests: XCTestCase {

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

    func testHostAndGlobalRoomFloorAtOne() {
        var budget = ConnectionBudget()
        budget.reserve(host: "h", count: 16)
        XCTAssertEqual(budget.hostRoom(host: "h", maxPerServer: 8), 1)
        XCTAssertEqual(budget.globalRoom(maxConnections: 10), 1)
    }

    func testExtraRoomUsesRawRoomWithoutFloorOne() {
        var budget = ConnectionBudget()
        XCTAssertEqual(budget.extraRoom(host: "h", profile: .medium), 8)

        budget.reserve(host: "h", count: 5)
        XCTAssertEqual(budget.extraRoom(host: "h", profile: .medium), 3)

        budget.reserve(host: "h", count: 3)
        XCTAssertEqual(budget.extraRoom(host: "h", profile: .medium), 0,
                       "a saturated host grants zero — the caller already holds a connection")

        budget.reserve(host: "h", count: 4)
        XCTAssertEqual(budget.extraRoom(host: "h", profile: .medium), 0)
    }

    func testExtraRoomTakesTheTighterOfHostAndGlobal() {
        var budget = ConnectionBudget()
        budget.reserve(host: "other", count: 198)
        XCTAssertEqual(budget.extraRoom(host: "h", profile: .medium), 2)
    }

    func testExtraRoomZeroWhenProfileForbidsExtraConnections() {
        let budget = ConnectionBudget()
        XCTAssertEqual(budget.extraRoom(host: "h", profile: .low), 0,
                       "Low never grants mid-flight extras, however much room exists")
    }

    func testLowProfileAlwaysOneSegment() {
        let budget = ConnectionBudget()
        let n = budget.resolveSegmentCount(total: 100 * 1024 * 1024, host: "h", profile: .low)
        XCTAssertEqual(n, 1)
    }

    func testHighProfileUsesPerServerCapWhenRoomFree() {
        let budget = ConnectionBudget()
        let n = budget.resolveSegmentCount(total: 100 * 1024 * 1024, host: "h", profile: .high)
        XCTAssertEqual(n, 16)
    }

    func testSegmentCountRespectsHostBudgetAlreadyInUse() {
        var budget = ConnectionBudget()
        budget.reserve(host: "h", count: 12)
        let n = budget.resolveSegmentCount(total: 100 * 1024 * 1024, host: "h", profile: .high)
        XCTAssertEqual(n, 4)
    }

    func testSegmentCountRespectsGlobalBudget() {
        var budget = ConnectionBudget()
        budget.reserve(host: "other", count: 198)
        let n = budget.resolveSegmentCount(total: 100 * 1024 * 1024, host: "h", profile: .medium)
        XCTAssertEqual(n, 2)
    }

    func testSegmentCountClampsByFileSize() {
        let budget = ConnectionBudget()
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
