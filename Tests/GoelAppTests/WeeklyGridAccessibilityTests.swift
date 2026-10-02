import XCTest
import GoelCore
@testable import GoelApp

/// The weekly profile grid without a mouse or colour vision: a letter per profile and a
/// keyboard cursor that stays on the grid.
final class WeeklyGridAccessibilityTests: XCTestCase {

    func testGlyphsAreTheShortestUnsharedPrefix() {
        XCTAssertEqual(ProfileScheduleSummary.glyphs(for: ["Night", "Normal", "Fast"]),
                       ["Night": "NI", "Normal": "NO", "Fast": "F"])
        XCTAssertEqual(ProfileScheduleSummary.glyphs(for: ["Low", "Medium", "High"]),
                       ["Low": "L", "Medium": "M", "High": "H"])
    }

    func testGlyphFallsBackToTheProfileNumber() {
        // "Fast" is a prefix of "Faster": no 1–2 letter prefix tells them apart.
        XCTAssertEqual(ProfileScheduleSummary.glyphs(for: ["Fast", "Faster"]), ["Fast": "1", "Faster": "2"])
    }

    func testArrowsStopAtTheGridEdges() {
        let corner = WeeklyGridCursor(day: 0, hour: 0)
        XCTAssertEqual(corner.moved(days: -1), corner)
        XCTAssertEqual(corner.moved(hours: -1), corner)
        XCTAssertEqual(corner.moved(days: 1, hours: 1), WeeklyGridCursor(day: 1, hour: 1))
        XCTAssertEqual(WeeklyGridCursor(day: 6, hour: 23).moved(days: 1, hours: 1), WeeklyGridCursor(day: 6, hour: 23))
    }

    func testAdjustingStepsThroughTheWeek() {
        XCTAssertEqual(WeeklyGridCursor(day: 0, hour: 23).stepped(by: 1), WeeklyGridCursor(day: 1, hour: 0))
        XCTAssertEqual(WeeklyGridCursor(day: 1, hour: 0).stepped(by: -1), WeeklyGridCursor(day: 0, hour: 23))
        XCTAssertEqual(WeeklyGridCursor(day: 0, hour: 0).stepped(by: -1), WeeklyGridCursor(day: 0, hour: 0))
        XCTAssertEqual(WeeklyGridCursor(day: 6, hour: 23).stepped(by: 1), WeeklyGridCursor(day: 6, hour: 23))
    }
}
