import XCTest
@testable import GoelCore

/// Unit coverage for the request-accumulation primitives that let a server shell
/// read a COMPLETE HTTP request before dispatching. These are the fix for the
/// macOS POST-body-truncation bug: a body split across TCP segments (or larger
/// than one read) used to be parsed empty → `/api/add` and `/login` failed 400.
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

    /// The completeness predicate the accumulator loops on: it must report
    /// "incomplete" until the headers AND the full Content-Length body arrive,
    /// then parse the reassembled body intact.
    func testCompletenessPredicateAcrossSplitSegments() throws {
        let head = "POST /api/add HTTP/1.1\r\nContent-Length: 5\r\n\r\n"
        var buf = Data(head.utf8)
        let start = try XCTUnwrap(RemoteRequest.headerEnd(buf))

        // Headers in, body absent → still incomplete.
        XCTAssertLessThan(buf.count - start, RemoteRequest.contentLength(buf.prefix(start)),
                          "body has not arrived yet")
        // Body trickles across two more segments.
        buf.append(Data("AB".utf8))
        XCTAssertLessThan(buf.count - start, RemoteRequest.contentLength(buf.prefix(start)))
        buf.append(Data("CDE".utf8))
        XCTAssertEqual(buf.count - start, RemoteRequest.contentLength(buf.prefix(start)),
                       "the full 5-byte body is now present")

        XCTAssertEqual(RemoteRequest(raw: buf).body, Data("ABCDE".utf8),
                       "the reassembled request parses the whole body")
    }
}
