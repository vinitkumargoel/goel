import XCTest
import GoelCore
@testable import GoelApp

/// `goeldownloader://` is web-triggerable: any page the user visits can fire it. These tests pin the
/// two things that keeps honest — the inner-scheme allowlist, and the confirmation flag.
@MainActor
final class ExternalAddRoutingTests: XCTestCase {

    private func payload(_ string: String) -> ExternalAdd.Payload? {
        guard let url = URL(string: string) else {
            XCTFail("‘\(string)’ is not a URL")
            return nil
        }
        return ExternalAdd.payload(from: url)
    }

    func testURLSchemeAddAlwaysAsksBeforeQueueing() throws {
        for inner in ["https://example.test/a.zip",
                      "http://example.test/a.zip",
                      "magnet:?xt=urn:btih:ABCDEF0123456789"] {
            let encoded = inner.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics) ?? inner
            let result = try XCTUnwrap(payload("goeldownloader://add?url=\(encoded)"),
                                       "‘\(inner)’ should route")
            XCTAssertEqual(result.lines, inner)
            XCTAssertTrue(result.needsConfirmation,
                          "a web page fired this — it must never enqueue silently")
            XCTAssertFalse(result.drainBrowserSpool)
        }
    }

    func testURLSchemeRefusesAnInnerSchemeOutsideTheAllowlist() {
        for inner in ["ftp://example.test/a.zip",
                      "file:///etc/passwd",
                      "javascript:alert(1)",
                      "data:text/html,hi",
                      "goeldownloader://add?url=https://example.test/loop.zip"] {
            let encoded = inner.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics) ?? inner
            XCTAssertNil(payload("goeldownloader://add?url=\(encoded)"),
                         "‘\(inner)’ is not an allowed inner target")
        }
    }

    func testURLSchemeWithNothingToAddIsIgnored() {
        XCTAssertNil(payload("goeldownloader://add"))
        XCTAssertNil(payload("goeldownloader://add?other=1"))
        XCTAssertNil(payload("goeldownloader://add?url="))
    }

    func testDrainRequestCarriesNoContentOfItsOwn() throws {
        let result = try XCTUnwrap(payload("goeldownloader://drain-browser-queue"))
        XCTAssertTrue(result.drainBrowserSpool)
        XCTAssertNil(result.lines, "the URL is a trigger — the spool on disk is the trust boundary")
        XCTAssertNil(result.torrentFile)
        XCTAssertFalse(result.needsConfirmation,
                       "a local process wrote the spool, so its contents need no second opinion")
    }

    func testDrainHostIsMatchedCaseInsensitively() throws {
        let result = try XCTUnwrap(payload("goeldownloader://Drain-Browser-Queue"))
        XCTAssertTrue(result.drainBrowserSpool)
    }

    func testAMagnetTheUserOpenedIsQueuedWithoutAsking() throws {
        let magnet = "magnet:?xt=urn:btih:ABCDEF0123456789"
        let result = try XCTUnwrap(payload(magnet))
        XCTAssertEqual(result.lines, magnet)
        XCTAssertFalse(result.needsConfirmation)
    }

    func testATorrentFileIsRoutedAsAFileNotAsText() throws {
        let result = try XCTUnwrap(payload("file:///tmp/ubuntu.torrent"))
        XCTAssertEqual(result.torrentFile?.path, "/tmp/ubuntu.torrent")
        XCTAssertNil(result.lines)
        XCTAssertFalse(result.needsConfirmation)
    }

    func testANonTorrentFileIsNotAnAdd() {
        XCTAssertNil(payload("file:///tmp/notes.txt"))
        XCTAssertNil(payload("file:///tmp/"))
    }

    func testAPlainHTTPSURLIsQueuedWithoutAsking() throws {
        let result = try XCTUnwrap(payload("https://example.test/a.zip"))
        XCTAssertEqual(result.lines, "https://example.test/a.zip")
        XCTAssertFalse(result.needsConfirmation)
    }

    func testTheOuterSchemeIsMatchedCaseInsensitively() throws {
        let encoded = "https://example.test/a.zip"
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        let result = try XCTUnwrap(payload("GOELDOWNLOADER://add?url=\(encoded)"))
        XCTAssertTrue(result.needsConfirmation,
                      "an uppercased scheme must not fall through to the trusted default branch")
    }
}
