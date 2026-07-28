import XCTest
@testable import GoelCore
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Exercises the interface-bound curl path against a real socket.
///
/// The unranged mode (`rangeStart < 0`) exists so a download pinned to one
/// interface still egresses it when the server does not support ranges — the
/// alternative was silently falling back to `URLSession`, which cannot bind, and
/// therefore ignoring the pin. Getting the C side wrong would send a malformed
/// `Range: bytes=-1--1` on every such request, so it is checked on the wire.
final class BoundHTTPClientTests: XCTestCase {

    /// Captures the request line + headers the server actually received.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func set(_ value: String) { lock.lock(); text = value; lock.unlock() }
        func get() -> String { lock.lock(); defer { lock.unlock() }; return text }
    }

    /// Accumulates the sizes handed to `onBytes` from the curl thread.
    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var sum = 0
        func add(_ n: Int) { lock.lock(); sum += n; lock.unlock() }
        var total: Int { lock.lock(); defer { lock.unlock() }; return sum }
    }

    /// One-shot HTTP/1.1 server on loopback. Hand-rolled because Foundation has no
    /// server and the portal's own listener is Network.framework — Darwin only,
    /// while interface binding is a Linux feature above all.
    ///
    /// It answers every request with `200 OK` and the full body — including ranged
    /// ones, which is exactly the "server ignored Range" case the bound path has
    /// to survive.
    private func serveOnce(body: Data, recorder: Recorder,
                           extraHeaders: [String: String] = [:]) throws -> UInt16 {
        let listener = socket(AF_INET, PlatformSocket.stream, 0)
        guard listener >= 0 else { throw XCTSkip("no socket") }

        var yes: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0                                  // kernel picks a free port
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                // Qualified: `bind` alone resolves to XCTestCase's own method.
                #if canImport(Glibc)
                Glibc.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #else
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #endif
            }
        }
        guard bound == 0, listen(listener, 1) == 0 else {
            close(listener)
            throw XCTSkip("could not listen on loopback")
        }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listener, $0, &length)
            }
        }
        guard named == 0 else { close(listener); throw XCTSkip("getsockname failed") }
        let port = UInt16(bigEndian: actual.sin_port)

        let thread = Thread {
            let client = accept(listener, nil, nil)
            close(listener)
            guard client >= 0 else { return }
            defer { close(client) }
            // curl hangs up the moment the C write thunk refuses a body (ranged
            // 200, external abort), so the remaining writes must fail the call —
            // not signal-kill the test process.
            #if canImport(Darwin)
            var noSigpipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe,
                       socklen_t(MemoryLayout<Int32>.size))
            let sendFlags: Int32 = 0
            #else
            let sendFlags = Int32(MSG_NOSIGNAL)
            #endif

            var request = ""
            var buffer = [UInt8](repeating: 0, count: 4096)
            while !request.contains("\r\n\r\n") {
                let n = read(client, &buffer, buffer.count)
                if n <= 0 { break }
                request += String(decoding: buffer[0..<n], as: UTF8.self)
            }
            recorder.set(request)

            let extra = extraHeaders.sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)\r\n" }.joined()
            let head = "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\n"
                     + "Content-Type: application/octet-stream\r\nConnection: close\r\n"
                     + extra + "\r\n"
            var out = Data(head.utf8)
            out.append(body)
            out.withUnsafeBytes { raw in
                var sent = 0
                while sent < raw.count {
                    let n = send(client, raw.baseAddress!.advanced(by: sent), raw.count - sent, sendFlags)
                    if n <= 0 { break }
                    sent += n
                }
            }
        }
        thread.stackSize = 1 << 19
        thread.start()
        return port
    }

    private func destination() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("bound-\(UUID().uuidString).bin")
    }

    private func request(port: UInt16, start: Int64, end: Int64,
                         interface: String = "") -> BoundHTTPClient.Request {
        BoundHTTPClient.Request(
            url: URL(string: "http://127.0.0.1:\(port)/file.bin")!,
            rangeStart: start, rangeEnd: end, interfaceName: interface,
            userAgent: "GoelTests/1.0", referer: nil, authorization: nil,
            extraHeaders: [:], connectTimeout: 10, expectedTotal: nil)
    }

    /// The whole point of the new mode: no `Range` header at all, full body.
    func testNegativeStartSendsNoRangeHeaderAndStreamsEverything() async throws {
        let payload = Data((0..<64_000).map { UInt8($0 % 251) })
        let recorder = Recorder()
        let port = try serveOnce(body: payload, recorder: recorder)

        let path = destination()
        defer { try? FileManager.default.removeItem(at: path) }
        FileManager.default.createFile(atPath: path.path, contents: nil)
        let handle = try FileHandle(forWritingTo: path)

        let response = await BoundHTTPClient.downloadRange(
            request(port: port, start: -1, end: -1), file: handle, fileOffset: 0, limiter: nil)
        try handle.close()

        XCTAssertEqual(response.curlCode, 0, "curl failed")
        XCTAssertEqual(response.httpStatus, 200)
        XCTAssertEqual(response.bytesWritten, Int64(payload.count))
        XCTAssertEqual(try Data(contentsOf: path), payload)

        let seen = recorder.get()
        XCTAssertFalse(seen.lowercased().contains("range:"),
                       "an unranged request must not carry a Range header:\n\(seen)")
    }

    /// The pre-existing ranged mode must keep sending exactly what it always did.
    func testRangedRequestStillSendsAnInclusiveRange() async throws {
        let payload = Data(repeating: 0x41, count: 4096)
        let recorder = Recorder()
        let port = try serveOnce(body: payload, recorder: recorder)

        let path = destination()
        defer { try? FileManager.default.removeItem(at: path) }
        FileManager.default.createFile(atPath: path.path, contents: nil)
        let handle = try FileHandle(forWritingTo: path)

        _ = await BoundHTTPClient.downloadRange(
            request(port: port, start: 100, end: 199), file: handle, fileOffset: 0, limiter: nil)
        try handle.close()

        XCTAssertTrue(recorder.get().contains("Range: bytes=100-199"),
                      "expected an inclusive range:\n\(recorder.get())")
    }

    /// An inverted range is a caller bug; it must be refused before a socket is
    /// opened rather than sent to the server as nonsense.
    func testInvertedRangeIsRejectedWithoutConnecting() async throws {
        let path = destination()
        defer { try? FileManager.default.removeItem(at: path) }
        FileManager.default.createFile(atPath: path.path, contents: nil)
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }

        // Port 1 is never listening; reaching the network at all would be the bug.
        let response = await BoundHTTPClient.downloadRange(
            request(port: 1, start: 500, end: 100), file: handle, fileOffset: 0, limiter: nil)
        XCTAssertNotEqual(response.curlCode, 0)
        XCTAssertEqual(response.bytesWritten, 0)
    }

    // MARK: Live byte accounting

    /// `Σ onBytes == Response.bytesWritten` is the invariant the segment pump's
    /// live ledger credits rest on: the pump now credits progress from the tally
    /// alone, so any divergence would double-count or lose bytes on every attempt.
    func testOnBytesTallyMatchesBytesWritten() async throws {
        let payload = Data((0..<64_000).map { UInt8($0 % 251) })
        let recorder = Recorder()
        let port = try serveOnce(body: payload, recorder: recorder)

        let path = destination()
        defer { try? FileManager.default.removeItem(at: path) }
        FileManager.default.createFile(atPath: path.path, contents: nil)
        let handle = try FileHandle(forWritingTo: path)

        let tally = Tally()
        let response = await BoundHTTPClient.downloadRange(
            request(port: port, start: -1, end: -1), file: handle, fileOffset: 0,
            limiter: nil, onBytes: { [tally] in tally.add($0) })
        try handle.close()

        XCTAssertEqual(response.curlCode, 0, "curl failed")
        XCTAssertEqual(Int64(tally.total), response.bytesWritten)
        XCTAssertEqual(response.bytesWritten, Int64(payload.count))
        XCTAssertEqual(try Data(contentsOf: path), payload)
    }

    /// The mid-flight upgrade stops a bound stream through `shouldAbort`. Nothing
    /// may reach the file after the flag flips, and the response has to say it
    /// aborted even when curl finished the same tick.
    func testShouldAbortStopsTransferAndReportsAborted() async throws {
        let payload = Data(repeating: 0x7E, count: 512 * 1024)
        let recorder = Recorder()
        let port = try serveOnce(body: payload, recorder: recorder)

        let path = destination()
        defer { try? FileManager.default.removeItem(at: path) }
        FileManager.default.createFile(atPath: path.path, contents: nil)
        let handle = try FileHandle(forWritingTo: path)

        // Flips after the first write callback, so the transfer is stopped
        // mid-body with a non-empty, fully accounted prefix on disk.
        let tally = Tally()
        let response = await BoundHTTPClient.downloadRange(
            request(port: port, start: -1, end: -1), file: handle, fileOffset: 0,
            limiter: nil,
            onBytes: { [tally] in tally.add($0) },
            shouldAbort: { [tally] in tally.total > 0 })
        try handle.close()

        XCTAssertTrue(response.aborted, "an external stop must surface as aborted")
        XCTAssertGreaterThan(response.bytesWritten, 0)
        XCTAssertLessThan(response.bytesWritten, Int64(payload.count), "the abort must land mid-body")
        XCTAssertEqual(Int64(tally.total), response.bytesWritten)
        let onDisk = try Data(contentsOf: path)
        XCTAssertEqual(Int64(onDisk.count), response.bytesWritten,
                       "the file must hold exactly the bytes the response claims")
    }

    // MARK: Validators + ranged 200

    /// The bound path has no `HTTPURLResponse`, so the C header thunk is the only
    /// place validators can come from — and without them the upgrade refuses to
    /// mix a streamed prefix with ranged tail bytes.
    func testResponseCarriesValidators() async throws {
        let payload = Data(repeating: 0x11, count: 1024)
        let recorder = Recorder()
        let port = try serveOnce(body: payload, recorder: recorder, extraHeaders: [
            "ETag": "\"abc\"",
            "Last-Modified": "Tue, 01 Jul 2025 00:00:00 GMT",
        ])

        let path = destination()
        defer { try? FileManager.default.removeItem(at: path) }
        FileManager.default.createFile(atPath: path.path, contents: nil)
        let handle = try FileHandle(forWritingTo: path)

        let response = await BoundHTTPClient.downloadRange(
            request(port: port, start: -1, end: -1), file: handle, fileOffset: 0, limiter: nil)
        try handle.close()

        XCTAssertEqual(response.curlCode, 0)
        XCTAssertEqual(response.etag, "\"abc\"", "captured verbatim, quotes included")
        XCTAssertEqual(response.lastModified, "Tue, 01 Jul 2025 00:00:00 GMT")
    }

    func testResponseValidatorsAreNilWhenHeadersAbsent() async throws {
        let payload = Data(repeating: 0x22, count: 512)
        let recorder = Recorder()
        let port = try serveOnce(body: payload, recorder: recorder)

        let path = destination()
        defer { try? FileManager.default.removeItem(at: path) }
        FileManager.default.createFile(atPath: path.path, contents: nil)
        let handle = try FileHandle(forWritingTo: path)

        let response = await BoundHTTPClient.downloadRange(
            request(port: port, start: -1, end: -1), file: handle, fileOffset: 0, limiter: nil)
        try handle.close()

        XCTAssertNil(response.etag, "an absent header is nil, not an empty string")
        XCTAssertNil(response.lastModified)
    }

    /// A ranged GET answered with a final 200 means the server ignored Range: the
    /// body is the whole file and useless to a segment. It must be refused before
    /// the first body byte, and must NOT report `aborted` — Swift reads that as a
    /// user pause and would hang the task.
    func testRangedTwoHundredAbortsEarlyWithRangeIgnored() async throws {
        let payload = Data(repeating: 0x3C, count: 256 * 1024)
        let recorder = Recorder()
        let port = try serveOnce(body: payload, recorder: recorder)

        let path = destination()
        defer { try? FileManager.default.removeItem(at: path) }
        FileManager.default.createFile(atPath: path.path, contents: nil)
        let handle = try FileHandle(forWritingTo: path)

        let tally = Tally()
        let response = await BoundHTTPClient.downloadRange(
            request(port: port, start: 0, end: 1023), file: handle, fileOffset: 0,
            limiter: nil, onBytes: { [tally] in tally.add($0) })
        try handle.close()

        XCTAssertEqual(response.httpStatus, 200)
        XCTAssertTrue(response.rangeIgnored)
        XCTAssertFalse(response.aborted, "a write-thunk refusal is not a pause")
        XCTAssertEqual(response.bytesWritten, 0)
        XCTAssertEqual(tally.total, 0, "not one body byte may reach the segment slot")
        XCTAssertEqual(try Data(contentsOf: path).count, 0)
    }

    /// Binding to loopback proves the socket option is honoured end to end.
    /// Skipped rather than failed where the sandbox forbids it — the assertion
    /// that matters (unranged wire format) is covered above without binding.
    func testBindingToLoopbackStillReachesTheServer() async throws {
        #if canImport(Glibc)
        let loopback = "lo"
        #else
        let loopback = "lo0"
        #endif
        let payload = Data(repeating: 0x5A, count: 2048)
        let recorder = Recorder()
        let port = try serveOnce(body: payload, recorder: recorder)

        let path = destination()
        defer { try? FileManager.default.removeItem(at: path) }
        FileManager.default.createFile(atPath: path.path, contents: nil)
        let handle = try FileHandle(forWritingTo: path)

        let response = await BoundHTTPClient.downloadRange(
            request(port: port, start: -1, end: -1, interface: loopback),
            file: handle, fileOffset: 0, limiter: nil)
        try handle.close()

        if response.curlCode != 0 {
            throw XCTSkip("binding to \(loopback) is not permitted here (curl \(response.curlCode))")
        }
        XCTAssertEqual(response.bytesWritten, Int64(payload.count))
        XCTAssertEqual(try Data(contentsOf: path), payload)
    }
}
