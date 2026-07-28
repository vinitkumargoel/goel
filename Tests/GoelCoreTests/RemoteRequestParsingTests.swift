import XCTest
@testable import GoelCore

final class RemoteRequestParsingTests: XCTestCase {

    func testHeaderEndNilUntilTerminatorArrives() {
        XCTAssertNil(RemoteRequest.headerEnd(Data("POST /api/add HTTP/1.1\r\nHost: x".utf8)),
                     "headers without the blank-line terminator are not complete")
        let full = "POST /api/add HTTP/1.1\r\nHost: x\r\n\r\n"
        XCTAssertEqual(RemoteRequest.headerEnd(Data(full.utf8)), full.utf8.count,
                       "index points just past the \\r\\n\\r\\n")
    }

    func testHeaderEndFindsBoundaryWithBodyPresent() throws {
        let raw = Data("GET / HTTP/1.1\r\n\r\nBODY".utf8)
        let end = try XCTUnwrap(RemoteRequest.headerEnd(raw))
        XCTAssertEqual(end, "GET / HTTP/1.1\r\n\r\n".utf8.count)
        XCTAssertEqual(raw.suffix(from: end), Data("BODY".utf8))
    }

    func testContentLengthParsedCaseInsensitively() {
        XCTAssertEqual(RemoteRequest.contentLength(Data("POST / HTTP/1.1\r\nContent-Length: 42\r\n".utf8)), 42)
        XCTAssertEqual(RemoteRequest.contentLength(Data("POST / HTTP/1.1\r\ncontent-length:  7 \r\n".utf8)), 7,
                       "case-insensitive name and surrounding whitespace are tolerated")
        XCTAssertEqual(RemoteRequest.contentLength(Data("GET / HTTP/1.1\r\nHost: x\r\n".utf8)), 0,
                       "absent Content-Length reads as 0")
    }

    func testCompletenessPredicateAcrossSplitSegments() throws {
        let head = "POST /api/add HTTP/1.1\r\nContent-Length: 5\r\n\r\n"
        var buf = Data(head.utf8)
        let start = try XCTUnwrap(RemoteRequest.headerEnd(buf))

        XCTAssertLessThan(buf.count - start, RemoteRequest.contentLength(buf.prefix(start)),
                          "body has not arrived yet")
        buf.append(Data("AB".utf8))
        XCTAssertLessThan(buf.count - start, RemoteRequest.contentLength(buf.prefix(start)))
        buf.append(Data("CDE".utf8))
        XCTAssertEqual(buf.count - start, RemoteRequest.contentLength(buf.prefix(start)),
                       "the full 5-byte body is now present")

        XCTAssertEqual(RemoteRequest(raw: buf).body, Data("ABCDE".utf8),
                       "the reassembled request parses the whole body")
    }
}
