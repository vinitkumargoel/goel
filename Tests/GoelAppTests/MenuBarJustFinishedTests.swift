import XCTest
import GoelCore
@testable import GoelApp

final class MenuBarJustFinishedTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func task(_ name: String, finishedAgo: TimeInterval?, status: DownloadStatus = .completed,
                      missing: Bool = false) -> DownloadTask {
        var t = DownloadTask(source: .url(URL(string: "https://example.test/\(name)")!),
                             name: name, saveDirectory: "/tmp", totalBytes: 10, status: status,
                             completedAt: finishedAgo.map { now.addingTimeInterval(-$0) })
        t.fileMissing = missing ? true : nil
        return t
    }

    func testNewestThreeFromTheLastDay() {
        let tasks = [
            task("old", finishedAgo: 25 * 3600),
            task("a", finishedAgo: 60),
            task("b", finishedAgo: 3600),
            task("c", finishedAgo: 10),
            task("d", finishedAgo: 7200),
        ]
        let shown = MenuBarJustFinished(tasks: tasks, now: now).shown.map(\.name)
        XCTAssertEqual(shown, ["c", "a", "b"])
    }

    func testOnlyCompletedRowsWithTheirFileStillThere() {
        let tasks = [
            task("seeding", finishedAgo: 10, status: .seeding),
            task("gone", finishedAgo: 10, missing: true),
            task("undated", finishedAgo: nil),
            task("ok", finishedAgo: 10),
        ]
        XCTAssertEqual(MenuBarJustFinished(tasks: tasks, now: now).shown.map(\.name), ["ok"])
    }
}
