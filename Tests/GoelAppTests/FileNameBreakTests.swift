import XCTest
@testable import GoelApp

final class FileNameBreakTests: XCTestCase {
    private let zwsp = "\u{200B}"

    func testBreaksFollowEachSeparator() {
        XCTAssertEqual("Cosmos.S01E04.2160p.HDR.mkv".breakingAtSeparators,
                       "Cosmos.\(zwsp)S01E04.\(zwsp)2160p.\(zwsp)HDR.\(zwsp)mkv")
        XCTAssertEqual("project-backup_2026.tar.zst".breakingAtSeparators,
                       "project-\(zwsp)backup_\(zwsp)2026.\(zwsp)tar.\(zwsp)zst")
    }

    func testRunsOfSeparatorsBreakOnceAndTrailingSeparatorsDoNot() {
        XCTAssertEqual("a--b".breakingAtSeparators, "a--\(zwsp)b")
        XCTAssertEqual("name.".breakingAtSeparators, "name.")
    }

    func testPlainNamesAreUnchangedAndTheVisibleTextIsPreserved() {
        XCTAssertEqual("Field Recordings".breakingAtSeparators, "Field Recordings")
        let name = "ubuntu-24.04.1-desktop-amd64.iso"
        XCTAssertEqual(name.breakingAtSeparators.replacingOccurrences(of: zwsp, with: ""), name)
    }
}
