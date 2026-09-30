import XCTest
@testable import GoelApp

final class SettingsRowSearchTests: XCTestCase {

    /// "sleep" should land on the row, labelled with its pane, not on three whole panes.
    func testRowsMatchSingleSettingsWithTheirPane() {
        let rows = SettingsSearch.rows(matching: "sleep", localize: { $0 })
        XCTAssertTrue(rows.contains { $0.title == "Prevent sleep during active downloads" && $0.pane == .general })
        XCTAssertFalse(rows.contains { $0.title.hasSuffix(".") }, "pane subtitles are not rows")
    }

    func testTooShortAQueryListsNothing() {
        XCTAssertTrue(SettingsSearch.rows(matching: "s", localize: { $0 }).isEmpty)
    }
}
