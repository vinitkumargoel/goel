import XCTest
import GoelCore
@testable import GoelApp

final class RowStateActionTests: XCTestCase {

    private func task(_ status: DownloadStatus, missing: Bool = false) -> DownloadTask {
        var t = DownloadTask(source: .url(URL(string: "https://e.test/a.bin")!), name: "a.bin",
                             saveDirectory: "/tmp", totalBytes: 10, status: status)
        t.fileMissing = missing ? true : nil
        return t
    }

    func testEachStateGetsItsOwnAction() {
        XCTAssertEqual(RowStateAction(task: task(.downloading)), .pause)
        XCTAssertEqual(RowStateAction(task: task(.seeding)), .pause)
        XCTAssertEqual(RowStateAction(task: task(.paused)), .resume)
        XCTAssertEqual(RowStateAction(task: task(.queued)), .resume)
        XCTAssertEqual(RowStateAction(task: task(.failed(.diskFull(needed: 100, available: 10)))), .retry)
    }

    /// A finished file opens on double-click and Return; the button only earns its place when the file went missing.
    func testCompletedRowsHaveNoButtonUnlessTheFileIsMissing() {
        XCTAssertNil(RowStateAction(task: task(.completed)))
        XCTAssertEqual(RowStateAction(task: task(.completed, missing: true)), .locate)
    }
}
