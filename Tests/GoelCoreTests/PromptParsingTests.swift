import XCTest
@testable import GoelCore

final class PromptParsingTests: XCTestCase {

    func testBatchRenameNumbersAndCarriesTheRightExtension() {
        let cases: [(template: String, over: [String], expected: [String], why: String)] = [
            ("Episode #", ["a.mkv", "b.mp4", "c"], ["Episode 1.mkv", "Episode 2.mp4", "Episode 3"],
             "running number substituted; original extension carried when the template omits one"),
            ("clip #.mov", ["x.mkv", "y.mp4"], ["clip 1.mov", "clip 2.mov"],
             "a template extension is kept as-is"),
            ("#-#", ["a.txt"], ["1-1.txt"], "every # is replaced, not just the first"),
            ("x #", [], [], "nothing to rename"),
        ]
        for c in cases {
            XCTAssertEqual(PromptParsing.batchRename(template: c.template, over: c.over),
                           c.expected, c.why)
        }
    }

    func testRequestHeadersParsesOnlyWellFormedLines() {
        let cases: [(text: String, expected: [String: String], why: String)] = [
            ("Authorization: Bearer xyz\nX-Api-Key:  secret \n\nnocolonhere\n: emptyname\nReferer:https://e.com",
             ["Authorization": "Bearer xyz", "X-Api-Key": "secret", "Referer": "https://e.com"],
             "blank / no-colon / empty-name lines are dropped"),
            ("X-Time: 10:30:00", ["X-Time": "10:30:00"], "only the first colon splits name from value"),
            ("A: 1\nA: 2", ["A": "2"], "a later duplicate wins"),
            ("", [:], "empty input"),
        ]
        for c in cases {
            XCTAssertEqual(PromptParsing.requestHeaders(from: c.text), c.expected, c.why)
        }
    }

    func testTagsSplitTrimAndDropEmpty() {
        XCTAssertEqual(PromptParsing.tags(from: " work ,urgent,, linux "), ["work", "urgent", "linux"])
        for blank in ["   ", "", ",, ,"] {
            XCTAssertEqual(PromptParsing.tags(from: blank), [], "‘\(blank)’ yields no tags")
        }
    }
}
