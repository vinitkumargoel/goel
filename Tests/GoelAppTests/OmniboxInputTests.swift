import XCTest
import GoelCore
@testable import GoelApp

final class OmniboxInputTests: XCTestCase {

    func testEmptyAndWhitespaceAreEmpty() {
        XCTAssertEqual(OmniboxInput.classify(""), .empty)
        XCTAssertEqual(OmniboxInput.classify("   \n "), .empty)
        XCTAssertEqual(OmniboxInput.classify("").searchText, "")
    }

    func testPlainWordsAreASearch() {
        XCTAssertEqual(OmniboxInput.classify("ubuntu"), .search("ubuntu"))
        XCTAssertEqual(OmniboxInput.classify("ubuntu").searchText, "ubuntu")
    }

    func testHostTokenStaysASearch() {
        // `host:` looks like a scheme to URL(string:), but it isn't on the allowlist.
        let input = OmniboxInput.classify("host:archive.org mozart")
        XCTAssertTrue(input.isSearch)
        XCTAssertEqual(input.searchText, "host:archive.org mozart")
        XCTAssertEqual(OmniboxInput.classify("host:example.com"), .search("host:example.com"))
    }

    func testHTTPLinkIsRecognised() {
        let input = OmniboxInput.classify("https://releases.ubuntu.com/24.04/ubuntu.iso")
        XCTAssertEqual(input.links.count, 1)
        XCTAssertEqual(input.searchText, "", "a link must not filter the list")
        let source = input.links[0]
        XCTAssertEqual(source.kind, .http)
        XCTAssertEqual(OmniboxInput.host(of: source), "releases.ubuntu.com")
        XCTAssertEqual(OmniboxInput.summary(of: source), "HTTP · releases.ubuntu.com")
        XCTAssertEqual(OmniboxInput.fileType(of: source), .iso)
    }

    func testMagnetAndStreamAreRecognised() {
        let magnet = OmniboxInput.classify("magnet:?xt=urn:btih:5c1a9d3e")
        XCTAssertEqual(magnet.links.first?.kind, .torrent)
        XCTAssertEqual(OmniboxInput.host(of: magnet.links[0]), "magnet")
        XCTAssertEqual(OmniboxInput.fileType(of: magnet.links[0]), .magnet)

        let stream = OmniboxInput.classify("https://cdn.example.com/live/master.m3u8")
        XCTAssertEqual(stream.links.first?.kind, .hls)
    }

    func testSeveralPastedLinksAreAllRecognised() {
        let input = OmniboxInput.classify("https://a.example/x.zip\nftp://b.example/y.iso\n")
        XCTAssertEqual(input.links.count, 2)
        XCTAssertEqual(input.links.map(\.kind), [.http, .ftp])
    }

    func testDisallowedSchemesAreASearch() {
        XCTAssertTrue(OmniboxInput.classify("file:///etc/passwd").isSearch)
        XCTAssertTrue(OmniboxInput.classify("javascript:alert(1)").isSearch)
    }
}
