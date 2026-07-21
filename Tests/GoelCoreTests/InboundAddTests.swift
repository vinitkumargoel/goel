import XCTest
@testable import GoelCore

/// Trust-rule cases for ``InboundAdd/classify`` — origin decides confirmation,
/// content decides ignore vs act. Parse coverage is thin (reuses BatchExpander
/// + DownloadSource); the heavy metalink path stays in the app layer.
final class InboundAddTests: XCTestCase {

    // MARK: classify — urlScheme

    func testURLSchemeWithLinesNeedsConfirmation() {
        let d = InboundAdd.classify(
            origin: .urlScheme,
            payload: .init(lines: "https://example.com/a.iso")
        )
        guard case .needsConfirmation(let p) = d else {
            return XCTFail("expected needsConfirmation, got \(d)")
        }
        XCTAssertEqual(p.lines, "https://example.com/a.iso")
    }

    func testURLSchemeWithTorrentNeedsConfirmation() {
        let d = InboundAdd.classify(
            origin: .urlScheme,
            payload: .init(torrentFilePath: "/tmp/x.torrent")
        )
        guard case .needsConfirmation = d else {
            return XCTFail("expected needsConfirmation, got \(d)")
        }
    }

    func testURLSchemeEmptyIgnored() {
        XCTAssertEqual(
            InboundAdd.classify(origin: .urlScheme, payload: .init()),
            .ignore
        )
        XCTAssertEqual(
            InboundAdd.classify(origin: .urlScheme, payload: .init(lines: "   \n  ")),
            .ignore
        )
    }

    // MARK: classify — userExplicit

    func testUserExplicitWithLinesEnqueues() {
        let d = InboundAdd.classify(
            origin: .userExplicit,
            payload: .init(lines: "magnet:?xt=urn:btih:abc")
        )
        guard case .enqueue(let p) = d else {
            return XCTFail("expected enqueue, got \(d)")
        }
        XCTAssertEqual(p.lines, "magnet:?xt=urn:btih:abc")
    }

    func testUserExplicitWithTorrentEnqueues() {
        let d = InboundAdd.classify(
            origin: .userExplicit,
            payload: .init(torrentFilePath: "/Users/me/a.torrent")
        )
        guard case .enqueue(let p) = d else {
            return XCTFail("expected enqueue, got \(d)")
        }
        XCTAssertEqual(p.torrentFilePath, "/Users/me/a.torrent")
    }

    func testUserExplicitEmptyIgnored() {
        XCTAssertEqual(
            InboundAdd.classify(origin: .userExplicit, payload: .init()),
            .ignore
        )
    }

    // MARK: classify — clipboard

    func testClipboardWithContentNeedsConfirmation() {
        let d = InboundAdd.classify(
            origin: .clipboard,
            payload: .init(lines: "https://cdn.example/file.zip")
        )
        guard case .needsConfirmation = d else {
            return XCTFail("expected needsConfirmation, got \(d)")
        }
    }

    func testClipboardEmptyIgnored() {
        XCTAssertEqual(
            InboundAdd.classify(origin: .clipboard, payload: .init(lines: nil)),
            .ignore
        )
    }

    // MARK: classify — browserSpool / drain

    func testBrowserSpoolContentFreeDrains() {
        XCTAssertEqual(
            InboundAdd.classify(origin: .browserSpool, payload: .init(drainBrowserSpool: true)),
            .drainSpool
        )
        XCTAssertEqual(
            InboundAdd.classify(origin: .browserSpool, payload: .init()),
            .drainSpool
        )
    }

    func testDrainFlagAloneDrainsEvenOnOtherOrigin() {
        // A content-free drain poke must drain regardless of how it was labeled —
        // the flag itself is the signal (native host / url-scheme poke).
        XCTAssertEqual(
            InboundAdd.classify(
                origin: .urlScheme,
                payload: .init(drainBrowserSpool: true)
            ),
            .drainSpool
        )
    }

    func testSpoolReaderWithLinesEnqueues() {
        let d = InboundAdd.classify(
            origin: .browserSpool,
            payload: .init(lines: "https://a.example/x.zip\nhttps://b.example/y.zip",
                           drainBrowserSpool: true)
        )
        guard case .enqueue(let p) = d else {
            return XCTFail("expected enqueue, got \(d)")
        }
        XCTAssertFalse(p.drainBrowserSpool, "enqueued spool payload must not re-trigger drain")
        XCTAssertEqual(p.lines, "https://a.example/x.zip\nhttps://b.example/y.zip")
    }

    // MARK: parseSources

    func testParseSourcesExpandsAndFilters() {
        let raw = """
        https://x.example/file[01-02].zip
        not-a-url
        magnet:?xt=urn:btih:deadbeef
        """
        let sources = InboundAdd.parseSources(from: raw)
        XCTAssertEqual(sources.count, 3)
        XCTAssertEqual(sources[0].locator, "https://x.example/file01.zip")
        XCTAssertEqual(sources[1].locator, "https://x.example/file02.zip")
        XCTAssertEqual(sources[2].kind, .torrent)
    }

    func testParseSourcesEmpty() {
        XCTAssertTrue(InboundAdd.parseSources(from: "\n  \n").isEmpty)
    }
}
