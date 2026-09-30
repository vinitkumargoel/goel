import XCTest
import GoelCore
@testable import GoelApp

final class InlineCredentialsTests: XCTestCase {

    func testTheLoginIsFoundAndTheSourceStaysClean() {
        let line = "https://alice:s3cr%40t@files.example.com/report.pdf"
        let found = InlineCredentials.find(in: line)
        XCTAssertEqual(found?.host, "files.example.com")
        XCTAssertEqual(found?.username, "alice")
        XCTAssertEqual(found?.password, "s3cr@t")
        XCTAssertEqual(found?.isTLS, true)
        XCTAssertFalse(DownloadSource.parse(line)!.locator.contains("alice"))
    }

    func testPlainLinksCarryNoLogin() {
        XCTAssertNil(InlineCredentials.find(in: "https://files.example.com/report.pdf"))
        XCTAssertNil(InlineCredentials.find(in: "magnet:?xt=urn:btih:abc"))
    }

    func testFindAllTakesOneLoginPerHost() {
        let raw = "https://a:1@h.test/x\nhttps://a:2@h.test/y\nhttps://b:3@k.test/z"
        XCTAssertEqual(InlineCredentials.findAll(in: raw).map(\.host), ["h.test", "k.test"])
    }

    func testOnlyLinesWithALoginAreHandedToTheManager() {
        let raw = "https://a:1@h.test/x\nhttps://plain.test/y\nmagnet:?xt=urn:btih:abc"
        XCTAssertEqual(InlineCredentials.linesWithLogins(in: raw), ["https://a:1@h.test/x"])
    }

    func testABrowserCapturesLoginIsRebuiltIntoItsLink() throws {
        let parsed = try XCTUnwrap(DownloadSource.parseWithCredentials("https://u:p%40ss@h.test/f.zip"))
        let target = try XCTUnwrap(parsed.source.fetchTargetURL)
        let line = try XCTUnwrap(InlineCredentials.line(for: target, authorization: try XCTUnwrap(parsed.authorization)))
        let found = InlineCredentials.find(in: line)
        XCTAssertEqual(found?.username, "u")
        XCTAssertEqual(found?.password, "p@ss")
        XCTAssertEqual(found?.host, "h.test")
        XCTAssertNil(InlineCredentials.line(for: target, authorization: "Bearer x"))
    }

    func testDecodeRoundTripsTheCoreHeader() {
        let parsed = DownloadSource.parseWithCredentials("https://u:p:q@h.test/f")
        let found = parsed?.authorization.flatMap {
            InlineCredentials.decode(authorization: $0, host: "h.test", isTLS: true)
        }
        XCTAssertEqual(found?.username, "u")
        XCTAssertEqual(found?.password, "p:q")
    }
}
