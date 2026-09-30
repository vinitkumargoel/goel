import XCTest
import GoelCore
@testable import GoelApp

final class CompletionSummaryTests: XCTestCase {

    private let english = Locale(identifier: "en_US")

    func testTookLineGivesDurationAndAverageSpeed() {
        let added = Date(timeIntervalSince1970: 1_000_000)
        let done = added.addingTimeInterval(252)          // 4m 12s
        let bytes: Int64 = 252 * 18_000_000               // 18 MB/s on average
        let line = CompletionSummary.tookLine(bytes: bytes, addedAt: added, completedAt: done, locale: english)
        XCTAssertEqual(line, "4m 12s · avg \(Double(18_000_000).speedString)")
    }

    func testTookLineWithoutBytesIsJustTheDuration() {
        let added = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(CompletionSummary.tookLine(bytes: 0, addedAt: added,
                                                  completedAt: added.addingTimeInterval(65), locale: english),
                       "1m 5s")
    }

    func testNoTookLineWithoutAFinishTimeOrWithABackwardsClock() {
        let added = Date()
        XCTAssertNil(CompletionSummary.tookLine(bytes: 10, addedAt: added, completedAt: nil))
        XCTAssertNil(CompletionSummary.tookLine(bytes: 10, addedAt: added,
                                                completedAt: added.addingTimeInterval(-5)))
    }

    func testFinishedLineJoinsSizeAndRelativeTime() {
        let done = Calendar.current.date(bySettingHour: 21, minute: 7, second: 0, of: Date())!
        let line = CompletionSummary.finishedLine(bytes: 2_900_000_000, completedAt: done, locale: english)
        XCTAssertTrue(line.hasPrefix("\(Int64(2_900_000_000).byteString) · finished "), line)
        XCTAssertTrue(line.contains(DisplayFormat.relativeDateTime(done, locale: english)), line)
    }

    func testFinishedLineFallsBackWhenPartsAreUnknown() {
        XCTAssertEqual(CompletionSummary.finishedLine(bytes: 0, completedAt: nil), "Finished")
        XCTAssertEqual(CompletionSummary.finishedLine(bytes: 1_000, completedAt: nil),
                       Int64(1_000).byteString)
    }

    func testSizePrefersTheDeclaredTotal() {
        var task = DownloadTask(source: .url(URL(string: "https://example.test/a.bin")!),
                                name: "a.bin", saveDirectory: "/tmp", totalBytes: 500, status: .completed)
        task.bytesDownloaded = 480
        XCTAssertEqual(CompletionSummary.size(of: task), 500)
        task.totalBytes = nil
        XCTAssertEqual(CompletionSummary.size(of: task), 480)
    }
}
