import XCTest
@testable import GoelCore

/// The socket read loop's accumulator: header decisions once, the body appended in place.
final class RemoteRequestReaderTests: XCTestCase {

    private let uploadHead = "POST /api/add-torrent HTTP/1.1\r\nContent-Type: multipart/form-data; boundary=x\r\n"

    private func feed(_ reader: inout RemoteRequestReader, _ data: Data, chunk: Int) -> [RemoteRequestReader.Step] {
        var steps: [RemoteRequestReader.Step] = []
        var offset = 0
        while offset < data.count {
            let end = min(offset + chunk, data.count)
            steps.append(reader.append(data.subdata(in: offset..<end)))
            offset = end
        }
        return steps
    }

    func testARequestSplitAcrossChunksCompletesOnlyWithItsLastByte() {
        let body = String(repeating: "a", count: 300)
        let raw = Data("POST /api/add HTTP/1.1\r\nContent-Length: 300\r\n\r\n\(body)".utf8)
        var reader = RemoteRequestReader()
        let steps = feed(&reader, raw, chunk: 7)
        XCTAssertEqual(steps.last, .complete)
        XCTAssertTrue(steps.dropLast().allSatisfy { $0 == .needMore })
        XCTAssertEqual(reader.buffer, raw)
        XCTAssertFalse(reader.isTorrentUpload)
    }

    func testALargeUploadStreamsToCompletionInSixtyFourKilobyteChunks() {
        let size = 20 * 1024 * 1024
        var raw = Data("\(uploadHead)Content-Length: \(size)\r\n\r\n".utf8)
        raw.append(Data(count: size))
        var reader = RemoteRequestReader()
        let steps = feed(&reader, raw, chunk: 65536)
        XCTAssertTrue(reader.isTorrentUpload)
        XCTAssertEqual(steps.last, .complete)
        XCTAssertFalse(steps.contains(.reject))
        XCTAssertEqual(reader.buffer.count, raw.count)
    }

    func testAnOversizedDeclaredLengthIsRefusedWithTheHeaders() {
        var general = RemoteRequestReader()
        XCTAssertEqual(general.append(Data("POST /api/add HTTP/1.1\r\nContent-Length: \(3 * 1024 * 1024)\r\n\r\n".utf8)),
                       .reject)
        var upload = RemoteRequestReader()
        XCTAssertEqual(upload.append(Data("\(uploadHead)Content-Length: \(64 * 1024 * 1024)\r\n\r\n".utf8)), .reject)
    }

    func testBytesPastTheCeilingAreRefusedEvenWithoutADeclaredLength() {
        var reader = RemoteRequestReader()
        XCTAssertEqual(reader.append(Data("POST /api/add HTTP/1.1\r\n\r\n".utf8)), .complete)
        var streaming = RemoteRequestReader()
        _ = streaming.append(Data("POST /api/add HTTP/1.1\r\nContent-Length: 10\r\n\r\n".utf8))
        XCTAssertEqual(streaming.append(Data(count: RemoteRequest.generalMaxRequestBytes)), .reject)
    }

    func testAHeaderBlockThatNeverEndsIsRefused() {
        var reader = RemoteRequestReader()
        let line = Data("X-Pad: \(String(repeating: "p", count: 1000))\r\n".utf8)
        var step = reader.append(Data("GET / HTTP/1.1\r\n".utf8))
        while step == .needMore, reader.buffer.count < 64 * 1024 { step = reader.append(line) }
        XCTAssertEqual(step, .reject)
    }
}
