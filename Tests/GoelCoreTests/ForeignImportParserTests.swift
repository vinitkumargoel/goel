import XCTest
@testable import GoelCore

final class ForeignImportParserTests: XCTestCase {

    func testExtractLocatorsHandlesEveryFormatWeAcceptAPasteFrom() {
        let cases: [(label: String, text: String, expected: [String])] = [
            ("an aria2 input file — option lines are not locators", """
             https://example.com/a.zip
               out=renamed.zip
               dir=/tmp
             https://example.com/b.iso
             """,
             ["https://example.com/a.zip", "https://example.com/b.iso"]),

            ("a JDownloader .crawljob", """
             [ { "text" : "https://cdn.example.com/file1.bin", "autoStart" : "TRUE" },
               { "text" : "https://cdn.example.com/file2.bin" } ]
             """,
             ["https://cdn.example.com/file1.bin", "https://cdn.example.com/file2.bin"]),

            ("magnet and ftp in prose, with trailing punctuation to strip",
             "See ftp://host/path/file.tar, and magnet:?xt=urn:btih:ABCDEF0123456789.",
             ["ftp://host/path/file.tar", "magnet:?xt=urn:btih:ABCDEF0123456789"]),

            ("duplicates collapse but the first position is kept", """
             https://example.com/x
             https://example.com/y
             https://example.com/x
             """,
             ["https://example.com/x", "https://example.com/y"]),

            ("prose with no links at all", "just some prose, no links here", []),
        ]
        for c in cases {
            XCTAssertEqual(ForeignImportParser.extractLocators(from: c.text), c.expected, c.label)
        }
    }
}
