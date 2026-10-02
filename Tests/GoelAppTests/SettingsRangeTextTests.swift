import XCTest
@testable import GoelApp

final class SettingsRangeTextTests: XCTestCase {

    func testRangesReadWithAnEnDash() {
        XCTAssertEqual(SettingsRangeText.text(1...3600), "1–3600")
        XCTAssertEqual(SettingsRangeText.text(0.0...1000.0), "0–1000")
    }

    func testDetailAppendsTheRange() {
        XCTAssertEqual(SettingsRangeText.detail("Port.", 1...65_535), "Port. Allowed: 1–65535.")
    }

    func testClampNoteNamesTypedAndUsedValues() {
        XCTAssertEqual(SettingsRangeText.clampNote(typed: "70000", range: 1...65_535, using: "65535"),
                       "70000 is outside 1–65535. Using 65535.")
    }
}
