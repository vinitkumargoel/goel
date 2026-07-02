import XCTest
@testable import GoelCore

/// Verifies the foreign-importer extracts locators from the shapes other download
/// managers / browsers produce, de-duplicates, and ignores non-URL noise.
final class ForeignImportParserTests: XCTestCase {

    func testAria2InputFileIgnoresOptionLines() {
        let text = """
        https://example.com/a.zip
          out=renamed.zip
          dir=/tmp
        https://example.com/b.iso
        """
        XCTAssertEqual(ForeignImportParser.extractLocators(from: text),
                       ["https://example.com/a.zip", "https://example.com/b.iso"])
    }

    func testJDownloaderCrawljobJSON() {
        let text = """
        [ { "text" : "https://cdn.example.com/file1.bin", "autoStart" : "TRUE" },
          { "text" : "https://cdn.example.com/file2.bin" } ]
        """
        XCTAssertEqual(ForeignImportParser.extractLocators(from: text),
                       ["https://cdn.example.com/file1.bin", "https://cdn.example.com/file2.bin"])
    }

    func testMagnetAndFTPAndTrailingPunctuation() {
        let text = "See ftp://host/path/file.tar, and magnet:?xt=urn:btih:ABCDEF0123456789."
        XCTAssertEqual(ForeignImportParser.extractLocators(from: text),
                       ["ftp://host/path/file.tar", "magnet:?xt=urn:btih:ABCDEF0123456789"])
    }

    func testDeduplicatesPreservingOrder() {
        let text = """
        https://example.com/x
        https://example.com/y
        https://example.com/x
        """
        XCTAssertEqual(ForeignImportParser.extractLocators(from: text),
                       ["https://example.com/x", "https://example.com/y"])
    }

    func testNoLinksReturnsEmpty() {
        XCTAssertTrue(ForeignImportParser.extractLocators(from: "just some prose, no links here").isEmpty)
    }
}
