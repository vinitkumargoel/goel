import XCTest
import GoelCore
@testable import GoelApp

/// The detail panel's Cookies fact: state and origin only, never a value.
final class DetailCookieStateTests: XCTestCase {
    private func task(source: CookieSource?, header: String?) -> DownloadTask {
        var t = DownloadTask(source: .url(URL(string: "https://e.test/a.bin")!), name: "a.bin",
                             saveDirectory: "/tmp", totalBytes: 1_000, status: .queued)
        t.cookieSource = source
        t.cookieHeader = header
        return t
    }

    func testNoCookiesShowNoRow() {
        XCTAssertNil(task(source: nil, header: nil).cookieStateText)
        XCTAssertNil(task(source: CookieSource.none, header: nil).cookieStateText)
    }

    func testAttachedCookiesShowCountAndSourceButNoValue() {
        let text = task(source: .browser, header: "sid=secret; theme=dark").cookieStateText
        XCTAssertEqual(text, "2 attached · From browser")
        XCTAssertFalse(text?.contains("secret") ?? true)
    }

    /// After a relaunch the values are gone; the row says where to get them again.
    func testUnloadedCookiesNameWhereToReimportFrom() {
        XCTAssertEqual(task(source: .browser, header: nil).cookieStateText,
                       "Not loaded — re-import from the browser")
        XCTAssertEqual(task(source: .manual, header: nil).cookieStateText,
                       "Not loaded — re-import from DevTools")
    }
}
