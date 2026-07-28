import XCTest
@testable import GoelCore

final class PromptParsingTests: XCTestCase {

    func testBatchRenameRunningNumberAndExtensionCarry() {
        let out = PromptParsing.batchRename(template: "Episode #", over: ["a.mkv", "b.mp4", "c"])
        XCTAssertEqual(out, ["Episode 1.mkv", "Episode 2.mp4", "Episode 3"],
                       "running number substituted; original extension carried when the template omits one")
    }

    func testBatchRenameExplicitTemplateExtensionWins() {
        let out = PromptParsing.batchRename(template: "clip #.mov", over: ["x.mkv", "y.mp4"])
        XCTAssertEqual(out, ["clip 1.mov", "clip 2.mov"], "a template extension is kept as-is")
    }

    func testBatchRenameReplacesEveryHash() {
        XCTAssertEqual(PromptParsing.batchRename(template: "#-#", over: ["a.txt"]), ["1-1.txt"])
    }

    func testBatchRenameEmpty() {
        XCTAssertEqual(PromptParsing.batchRename(template: "x #", over: []), [])
    }

    func testRequestHeadersTrimsSkipsAndParses() {
        let text = "Authorization: Bearer xyz\nX-Api-Key:  secret \n\nnocolonhere\n: emptyname\nReferer:https://e.com"
        let h = PromptParsing.requestHeaders(from: text)
        XCTAssertEqual(h, [
            "Authorization": "Bearer xyz",
            "X-Api-Key": "secret",
            "Referer": "https://e.com",
        ], "blank / no-colon / empty-name lines are dropped")
    }

    func testRequestHeadersValueKeepsInnerColons() {
        XCTAssertEqual(PromptParsing.requestHeaders(from: "X-Time: 10:30:00")["X-Time"], "10:30:00",
                       "only the first colon splits name from value")
    }

    func testRequestHeadersLaterDuplicateWins() {
        XCTAssertEqual(PromptParsing.requestHeaders(from: "A: 1\nA: 2")["A"], "2")
    }

    func testRequestHeadersEmpty() {
        XCTAssertTrue(PromptParsing.requestHeaders(from: "").isEmpty)
    }

    func testTagsSplitTrimAndDropEmpty() {
        XCTAssertEqual(PromptParsing.tags(from: " work ,urgent,, linux "), ["work", "urgent", "linux"])
    }

    func testTagsBlankInputIsEmpty() {
        XCTAssertEqual(PromptParsing.tags(from: "   "), [])
        XCTAssertEqual(PromptParsing.tags(from: ""), [])
        XCTAssertEqual(PromptParsing.tags(from: ",, ,"), [])
    }
}
