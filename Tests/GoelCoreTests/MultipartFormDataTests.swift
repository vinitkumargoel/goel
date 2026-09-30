import XCTest
@testable import GoelCore

final class MultipartFormDataTests: XCTestCase {

    private typealias MP = MultipartFormData

    private func body(_ text: String) -> Data { Data(text.utf8) }

    // MARK: - Content-Type boundary

    func testBoundaryFromPlainAndQuotedParameters() throws {
        XCTAssertEqual(try MP.boundary(fromContentType: "multipart/form-data; boundary=abc123"), "abc123")
        XCTAssertEqual(try MP.boundary(fromContentType: "Multipart/Form-Data;boundary=\"a b;c\""), "a b;c")
        XCTAssertEqual(try MP.boundary(
            fromContentType: "multipart/form-data; charset=utf-8; BOUNDARY=----WebKitFormBoundaryX"),
                       "----WebKitFormBoundaryX")
    }

    func testBoundaryRejectsOtherMediaTypesAndBadBoundaries() {
        XCTAssertThrowsError(try MP.boundary(fromContentType: nil)) {
            XCTAssertEqual($0 as? MP.ParseError, .notMultipart)
        }
        XCTAssertThrowsError(try MP.boundary(fromContentType: "application/json")) {
            XCTAssertEqual($0 as? MP.ParseError, .notMultipart)
        }
        XCTAssertThrowsError(try MP.boundary(fromContentType: "multipart/mixed; boundary=x")) {
            XCTAssertEqual($0 as? MP.ParseError, .notMultipart)
        }
        for bad in ["multipart/form-data", "multipart/form-data; boundary=",
                    "multipart/form-data; boundary=\"\"",
                    "multipart/form-data; boundary=" + String(repeating: "x", count: 71),
                    "multipart/form-data; boundary=\"trailing \"",
                    "multipart/form-data; boundary=\"unterminated",
                    "multipart/form-data; boundary=caf\u{e9}"] {
            XCTAssertThrowsError(try MP.boundary(fromContentType: bad), bad) {
                XCTAssertEqual($0 as? MP.ParseError, .missingBoundary, bad)
            }
        }
    }

    // MARK: - Parsing

    func testParsesFilesAndTextFields() throws {
        let raw = "--XyZ\r\n"
            + "Content-Disposition: form-data; name=\"dir\"\r\n\r\n"
            + "/data/dl\r\n"
            + "--XyZ\r\n"
            + "Content-Disposition: form-data; name=\"file\"; filename=\"C:\\dl\\a;b %22q%22.torrent\"\r\n"
            + "Content-Type: application/x-bittorrent\r\n\r\n"
            + "d4:infod4:name1:xee\r\n"
            + "--XyZ--\r\n"
        let parts = try MP.parse(body(raw), boundary: "XyZ", maxParts: 10)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0].name, "dir")
        XCTAssertNil(parts[0].filename)
        XCTAssertEqual(String(decoding: parts[0].body, as: UTF8.self), "/data/dl")
        XCTAssertEqual(parts[1].name, "file")
        XCTAssertEqual(parts[1].filename, "C:\\dl\\a;b %22q%22.torrent")
        XCTAssertEqual(parts[1].contentType, "application/x-bittorrent")
        XCTAssertEqual(String(decoding: parts[1].body, as: UTF8.self), "d4:infod4:name1:xee")
    }

    func testBinaryBodyWithCRLFAndDashesSurvivesIntact() throws {
        var payload = Data([0x64, 0x00, 0xFF, 0x0D, 0x0A, 0x2D, 0x2D, 0x58, 0x0D, 0x0A, 0x65])
        payload.append(Data("\r\n--XyZnot-a-delimiter-because-no-CRLF-before".utf8).dropFirst(2))
        var raw = body("--XyZ\r\nContent-Disposition: form-data; name=\"file\"; filename=\"b.torrent\"\r\n\r\n")
        raw.append(payload)
        raw.append(body("\r\n--XyZ--"))
        let parts = try MP.parse(raw, boundary: "XyZ", maxParts: 5)
        XCTAssertEqual(parts.first?.body, payload)
    }

    func testPreambleAndEpilogueAreIgnored() throws {
        let raw = "This is a preamble.\r\n--b\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\n1\r\n--b--\r\nepilogue"
        let parts = try MP.parse(body(raw), boundary: "b", maxParts: 5)
        XCTAssertEqual(parts.map(\.name), ["x"])
    }

    func testEmptyPartBodyAndTransportPadding() throws {
        let raw = "--b \t\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\n\r\n--b--"
        let parts = try MP.parse(body(raw), boundary: "b", maxParts: 5)
        XCTAssertEqual(parts.first?.body, Data())
    }

    /// The route receives `RemoteRequest.body`, a slice whose indices do not start at zero.
    func testParsesASliceWithANonZeroStartIndex() throws {
        let full = body("HEADERS\r\n\r\n--b\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\nv\r\n--b--")
        let slice = full.suffix(from: 11)
        XCTAssertNotEqual(slice.startIndex, 0)
        let parts = try MP.parse(slice, boundary: "b", maxParts: 5)
        XCTAssertEqual(parts.first.map { String(decoding: $0.body, as: UTF8.self) }, "v")
    }

    func testMalformedBodiesAreRejected() {
        let cases: [String: String] = [
            "no delimiter at all": "just some bytes",
            "missing closing delimiter": "--b\r\nContent-Disposition: form-data; name=\"x\"\r\n\r\nvalue",
            "headers never end": "--b\r\nContent-Disposition: form-data; name=\"x\"\r\nvalue\r\n--b--",
            "no CRLF after delimiter": "--bXContent-Disposition: form-data; name=\"x\"\r\n\r\nv\r\n--b--",
            "missing name": "--b\r\nContent-Disposition: form-data; filename=\"a\"\r\n\r\nv\r\n--b--",
            "empty name": "--b\r\nContent-Disposition: form-data; name=\"\"\r\n\r\nv\r\n--b--",
            "not form-data": "--b\r\nContent-Disposition: attachment; name=\"x\"\r\n\r\nv\r\n--b--",
            "header without colon": "--b\r\nContent-Disposition form-data\r\n\r\nv\r\n--b--",
            "no disposition": "--b\r\nContent-Type: text/plain\r\n\r\nv\r\n--b--",
            "truncated right after delimiter": "--b",
            "empty body": "",
        ]
        for (label, raw) in cases {
            XCTAssertThrowsError(try MP.parse(body(raw), boundary: "b", maxParts: 5), label) {
                XCTAssertEqual($0 as? MP.ParseError, .malformed, label)
            }
        }
    }

    func testInvalidUTF8InPartHeadersIsMalformed() {
        var raw = body("--b\r\nContent-Disposition: form-data; name=\"")
        raw.append(contentsOf: [0xFF, 0xFE])
        raw.append(body("\"\r\n\r\nv\r\n--b--"))
        XCTAssertThrowsError(try MP.parse(raw, boundary: "b", maxParts: 5)) {
            XCTAssertEqual($0 as? MP.ParseError, .malformed)
        }
    }

    func testPartCountIsCapped() {
        var raw = ""
        for i in 0..<4 { raw += "--b\r\nContent-Disposition: form-data; name=\"f\(i)\"\r\n\r\nv\r\n" }
        raw += "--b--"
        XCTAssertNoThrow(try MP.parse(body(raw), boundary: "b", maxParts: 4))
        XCTAssertThrowsError(try MP.parse(body(raw), boundary: "b", maxParts: 3)) {
            XCTAssertEqual($0 as? MP.ParseError, .tooManyParts)
        }
    }

    func testOversizedPartHeadersAreRejected() {
        let filler = String(repeating: "a", count: MP.maxPartHeaderBytes + 10)
        let raw = "--b\r\nContent-Disposition: form-data; name=\"x\"\r\nX-Pad: \(filler)\r\n\r\nv\r\n--b--"
        XCTAssertThrowsError(try MP.parse(body(raw), boundary: "b", maxParts: 5)) {
            XCTAssertEqual($0 as? MP.ParseError, .headersTooLarge)
        }
    }

    func testParameterSplittingHonoursQuotes() {
        XCTAssertEqual(MP.splitParameters("form-data; name=\"a;b\"; filename=x"),
                       ["form-data", " name=\"a;b\"", " filename=x"])
        XCTAssertNil(MP.keyValue("novalue"))
        XCTAssertNil(MP.keyValue("=x"))
        XCTAssertNil(MP.keyValue("k=\"dangling"))
        XCTAssertNil(MP.keyValue("k=\"a\"b\""))
        XCTAssertEqual(MP.keyValue(" Name = \"v\" ").map { [$0.0, $0.1] }, ["name", "v"])
    }
}
