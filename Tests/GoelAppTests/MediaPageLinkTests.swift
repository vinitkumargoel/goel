import XCTest
@testable import GoelApp

final class MediaPageLinkTests: XCTestCase {

    private func page(_ s: String) -> Bool { MediaPageLink.isLikelyVideoPage(URL(string: s)!) }

    func testKnownVideoPagesQualify() {
        XCTAssertTrue(page("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertTrue(page("https://m.youtube.com/shorts/abc123"))
        XCTAssertTrue(page("https://youtu.be/dQw4w9WgXcQ"))
        XCTAssertTrue(page("https://vimeo.com/123456"))
        XCTAssertTrue(page("https://x.com/someone/status/1790000000"))
        XCTAssertTrue(page("https://www.reddit.com/r/videos/comments/abc/title/"))
    }

    func testOrdinaryPagesAndFilesDoNot() {
        XCTAssertFalse(page("https://www.youtube.com/"))
        XCTAssertFalse(page("https://www.youtube.com/watch"))
        XCTAssertFalse(page("https://vimeo.com/about"))
        XCTAssertFalse(page("https://example.com/watch?v=1"))
        XCTAssertFalse(page("ftp://youtube.com/watch?v=1"))
        XCTAssertFalse(page("https://x.com/someone"))
    }
}
