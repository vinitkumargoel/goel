import XCTest
import GoelCore
@testable import GoelApp

final class DisplayFormatTests: XCTestCase {

    private let english = Locale(identifier: "en_US")
    private let british = Locale(identifier: "en_GB")
    private let german = Locale(identifier: "de_DE")

    // MARK: ETA

    /// The GUI used to say "1.5h" where the CLI said "1h 30m".
    func testEtaUsesWholeUnitsNotDecimalHours() {
        XCTAssertEqual(DownloadTask.etaString(5400, locale: english), "1h 30m")
    }

    func testEtaShowsAtMostTwoUnits() {
        XCTAssertEqual(DownloadTask.etaString(3 * 3600 + 25 * 60 + 12, locale: english), "3h 25m")
        XCTAssertEqual(DownloadTask.etaString(245, locale: english), "4m 5s")
        XCTAssertEqual(DownloadTask.etaString(12, locale: english), "12s")
    }

    func testSubSecondEtaRoundsUpToOneSecond() {
        XCTAssertEqual(DownloadTask.etaString(0.3, locale: english), "1s")
    }

    func testEtaFollowsTheLocale() {
        let german = DownloadTask.etaString(5400, locale: german)
        XCTAssertNotEqual(german, "1h 30m")
        XCTAssertTrue(german.contains("1"), german)
        XCTAssertTrue(german.contains("30"), german)
    }

    // MARK: Added date

    private func todayAt(hour: Int, minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date())!
    }

    func testTodayIsSaidInTheLocaleLanguage() {
        let date = todayAt(hour: 14, minute: 3)
        XCTAssertTrue(DownloadTask.addedString(for: date, locale: english).contains("Today"))
        XCTAssertTrue(DownloadTask.addedString(for: date, locale: german).contains("Heute"))
    }

    /// The old fixed "HH:mm" forced a 24-hour clock on every locale.
    func testClockStyleFollowsTheLocale() {
        let date = todayAt(hour: 14, minute: 3)
        XCTAssertTrue(DownloadTask.addedString(for: date, locale: british).contains("14:03"))
        XCTAssertTrue(DownloadTask.addedString(for: date, locale: english).contains("2:03"))
    }

    func testYesterdayIsRelative() {
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: todayAt(hour: 9, minute: 0))!
        XCTAssertTrue(DownloadTask.addedString(for: yesterday, locale: english).contains("Yesterday"))
    }

    func testOlderDatesAreAbsoluteAndNotRelative() {
        let older = Calendar.current.date(byAdding: .day, value: -10, to: todayAt(hour: 9, minute: 5))!
        let text = DownloadTask.addedString(for: older, locale: british)
        XCTAssertFalse(text.contains("Today"))
        XCTAssertFalse(text.contains("Yesterday"))
        XCTAssertTrue(text.contains("09:05"), text)
    }

    /// "Yesterday at 11:45 PM" was cut to "Yesterday at 1…" in the list column.
    func testTheListColumnIsCompact() {
        let now = todayAt(hour: 15, minute: 0)
        let today = todayAt(hour: 14, minute: 3)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: todayAt(hour: 23, minute: 45))!
        XCTAssertEqual(DisplayFormat.compactDateTime(today, locale: british, now: now), "Today 14:03")
        let older = DisplayFormat.compactDateTime(yesterday, locale: english, now: now)
        XCTAssertFalse(older.contains(" at "), "no “at”, so it fits the column")
        XCTAssertLessThanOrEqual(older.count, 18, older)
    }

    // MARK: Enum titles

    func testSortKeyTitlesAreHumanNotRawValues() {
        XCTAssertEqual(SortKey.index.title, "Queue order")
        XCTAssertEqual(SortKey.index.columnTitle, "#")
        XCTAssertEqual(SortKey.downloadSpeed.columnTitle, "↓ Speed")
        XCTAssertEqual(SortKey.uploadSpeed.title, "Upload speed")
        for key in SortKey.allCases { XCTAssertFalse(key.title.isEmpty) }
    }
}
