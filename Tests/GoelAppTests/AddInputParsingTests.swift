import XCTest
import GoelCore
@testable import GoelApp

/// The paste box is the widest untrusted input in the app: whatever survives here gets queued.
@MainActor
final class AddInputParsingTests: XCTestCase {

    /// The add path now parses through the shared `InboundAdd.parseSources`, the same one the
    /// daemon and portal use; these compare what it would queue.
    private func expanded(_ raw: String) -> [String] {
        InboundAdd.parseSources(from: raw).map(\.locator)
    }

    func testEachLineBecomesItsOwnEntry() {
        XCTAssertEqual(
            expanded("https://e.test/a.zip\nhttps://e.test/b.zip"),
            ["https://e.test/a.zip", "https://e.test/b.zip"])
    }

    func testBlankLinesAndSurroundingWhitespaceAreDiscarded() {
        XCTAssertEqual(
            expanded("\n  https://e.test/a.zip  \n\n\t\n"),
            ["https://e.test/a.zip"])
        XCTAssertEqual(expanded(""), [])
        XCTAssertEqual(expanded("   \n\t\n  "), [])
    }

    func testOneLineCanFanOutIntoMany() {
        XCTAssertEqual(
            expanded("https://e.test/f[1-3].zip"),
            ["https://e.test/f1.zip", "https://e.test/f2.zip", "https://e.test/f3.zip"])
    }

    func testFanOutAppliesPerLineAndKeepsTheOrderTheUserTyped() {
        XCTAssertEqual(
            expanded("https://e.test/a[1-2].zip\nhttps://e.test/b.zip"),
            ["https://e.test/a1.zip", "https://e.test/a2.zip", "https://e.test/b.zip"])
    }

    /// A pasted `[1-999999]` must not materialise a million rows before anything can stop it.
    func testAnOverCapRangeIsLeftAloneRatherThanExpanded() {
        let hostile = "https://e.test/f[1-999999].zip"
        // One entry (the literal, percent-encoded by the URL parser), never a million.
        XCTAssertEqual(expanded(hostile).count, 1)
        XCTAssertTrue(expanded(hostile)[0].contains("999999"))
    }

    func testAMagnetIsNeverTreatedAsAPattern() {
        // Trackers routinely carry [] in query values; expanding them would corrupt the magnet.
        let magnet = "magnet:?xt=urn:btih:ABCDEF0123456789&tr=udp%3A%2F%2Ft.test%3A80%2F[a,b]"
        XCTAssertEqual(expanded(magnet), [magnet])
    }

    func testMetalinkIsRecognisedByExtensionRegardlessOfCase() {
        for name in ["list.metalink", "list.meta4", "list.METALINK", "LIST.Meta4"] {
            let source = DownloadSource.url(URL(string: "https://e.test/\(name)")!)
            XCTAssertTrue(AppViewModel.isMetalink(source), name)
        }
    }

    func testOrdinaryDownloadsAreNotMetalinks() {
        for name in ["archive.zip", "metalink", "notmetalink.zip", "a.metalink.zip"] {
            let source = DownloadSource.url(URL(string: "https://e.test/\(name)")!)
            XCTAssertFalse(AppViewModel.isMetalink(source), name)
        }
    }

    func testAMagnetIsNeverAMetalink() {
        XCTAssertFalse(AppViewModel.isMetalink(.magnet("magnet:?xt=urn:btih:ABCDEF0123456789")))
    }

    func testParseSourceRefusesLocalFileAndScriptSchemes() {
        for hostile in ["file:///etc/passwd", "javascript:alert(1)", "data:text/html,hi",
                        "jar:file:///x!/y", "\\\\server\\share\\file"] {
            XCTAssertNil(AppViewModel.parseSource(hostile), "‘\(hostile)’ must not become a source")
        }
    }

    func testParseSourceAcceptsTheTransferSchemesTheAppActuallySupports() {
        for good in ["https://e.test/a.zip", "http://e.test/a.zip",
                     "ftp://e.test/a.zip", "sftp://e.test/a.zip",
                     "magnet:?xt=urn:btih:ABCDEF0123456789"] {
            XCTAssertNotNil(AppViewModel.parseSource(good), good)
        }
    }

    func testParseSourceRejectsProseAndEmptyInput() {
        for junk in ["", "   ", "just some words", "example.test/a.zip"] {
            XCTAssertNil(AppViewModel.parseSource(junk), "‘\(junk)’")
        }
    }
}
