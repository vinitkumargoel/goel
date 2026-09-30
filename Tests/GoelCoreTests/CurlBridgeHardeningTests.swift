import XCTest
import CurlBridge
@testable import GoelCore
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// FFI-1/2/6/7, ENG-6/8, PERF-1 on the curl (bound) path.
final class CurlBridgeHardeningTests: XCTestCase {

    // MARK: Redirect resolution (FFI-1, FFI-2)

    private func resolve(_ base: String, _ loc: String) -> String? {
        guard let raw = gcb_resolve_location(base, loc) else { return nil }
        defer { gcb_free(raw) }
        return String(cString: raw)
    }

    func testSchemeRelativeLocationKeepsTheScheme() {
        XCTAssertEqual(resolve("https://origin.example/dl/file.bin", "//edge.cdn.net/file.bin"),
                       "https://edge.cdn.net/file.bin")
    }

    func testRelativeLocationIgnoresSlashesInTheQuery() {
        XCTAssertEqual(resolve("https://h.example/a/b?next=/x/y", "c.bin"), "https://h.example/a/c.bin")
        XCTAssertEqual(resolve("https://h.example/a/b", "/root.bin"), "https://h.example/root.bin")
        XCTAssertEqual(resolve("https://h.example/a/b", "https://other.example/z"), "https://other.example/z")
    }

    func testLongPresignedLocationIsNotTruncated() {
        let signature = String(repeating: "A", count: 3_500)
        let loc = "https://bucket.s3.example/obj?X-Amz-Signature=\(signature)"
        XCTAssertEqual(resolve("https://origin.example/x", loc), loc)
    }

    // MARK: Secret scoping across redirects (FFI-7)

    func testSecretsOnlyFollowTheSameOrigin() {
        XCTAssertEqual(gcb_redirect_keeps_secrets("https://h.example/a", "https://h.example/b"), 1)
        XCTAssertEqual(gcb_redirect_keeps_secrets("https://h.example/a", "https://h.example:443/b"), 1)
        XCTAssertEqual(gcb_redirect_keeps_secrets("https://h.example/a", "https://h.example:8443/b"), 0,
                       "a port change is a different server")
        XCTAssertEqual(gcb_redirect_keeps_secrets("https://h.example/a", "http://h.example/b"), 0)
        XCTAssertEqual(gcb_redirect_keeps_secrets("http://h.example/a", "https://h.example/b"), 1)
        XCTAssertEqual(gcb_redirect_keeps_secrets("https://h.example/a", "https://evil.example/b"), 0)
    }

    // MARK: Loopback 206 server

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var text = ""
        func set(_ value: String) { lock.lock(); text = value; lock.unlock() }
        func get() -> String { lock.lock(); defer { lock.unlock() }; return text }
    }

    /// One connection; `respond` builds the raw response from the request head.
    private func serveOnce(recorder: Recorder, respond: @escaping @Sendable (String) -> Data) throws -> UInt16 {
        let listener = socket(AF_INET, PlatformSocket.stream, 0)
        guard listener >= 0 else { throw XCTSkip("no socket") }
        var yes: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if canImport(Glibc)
                Glibc.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #else
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #endif
            }
        }
        guard bound == 0, listen(listener, 1) == 0 else { close(listener); throw XCTSkip("no listen") }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        let port = UInt16(bigEndian: actual.sin_port)
        let thread = Thread {
            let client = accept(listener, nil, nil)
            close(listener)
            guard client >= 0 else { return }
            defer { close(client) }
            #if canImport(Darwin)
            var noSigpipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
            let flags: Int32 = 0
            #else
            let flags = Int32(MSG_NOSIGNAL)
            #endif
            var request = ""
            var buffer = [UInt8](repeating: 0, count: 8192)
            while !request.contains("\r\n\r\n") {
                let n = read(client, &buffer, buffer.count)
                if n <= 0 { break }
                request += String(decoding: buffer[0..<n], as: UTF8.self)
            }
            recorder.set(request)
            let out = respond(request)
            out.withUnsafeBytes { raw in
                var sent = 0
                while sent < raw.count {
                    let n = send(client, raw.baseAddress!.advanced(by: sent), raw.count - sent, flags)
                    if n <= 0 { break }
                    sent += n
                }
            }
        }
        thread.start()
        return port
    }

    private func partial(_ body: Data, start: Int, end: Int, total: Int, etag: String = "\"e1\"") -> Data {
        var out = Data(("HTTP/1.1 206 Partial Content\r\nContent-Range: bytes \(start)-\(end)/\(total)\r\n"
                        + "Content-Length: \(body.count)\r\nETag: \(etag)\r\nConnection: close\r\n\r\n").utf8)
        out.append(body)
        return out
    }

    private func tempFile() throws -> (URL, FileHandle) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bridge-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return (url, try FileHandle(forWritingTo: url))
    }

    private func request(_ port: UInt16, start: Int64, end: Int64, total: Int64?,
                         headers: [String: String] = [:], ifRange: String? = nil) -> BoundHTTPClient.Request {
        BoundHTTPClient.Request(
            url: URL(string: "http://127.0.0.1:\(port)/f.bin")!, rangeStart: start, rangeEnd: end,
            interfaceName: "", userAgent: "GoelTests/1.0", referer: nil, authorization: nil,
            extraHeaders: headers, connectTimeout: 10, expectedTotal: total, ifRange: ifRange)
    }

    func testOvershootingPartialIsClampedToTheRequestedRange() async throws {
        let payload = ScriptedURLProtocol.payload(4096)
        let recorder = Recorder()
        // Asked for 1000-1999; the proxy runs to EOF.
        let port = try serveOnce(recorder: recorder) { _ in
            self.partial(payload.subdata(in: 1000..<4096), start: 1000, end: 4095, total: 4096)
        }
        let (url, handle) = try tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let response = await BoundHTTPClient.downloadRange(
            request(port, start: 1000, end: 1999, total: 4096), file: handle, fileOffset: 0, limiter: nil)
        try handle.close()
        XCTAssertEqual(response.curlCode, 0, "having every requested byte is success")
        XCTAssertEqual(response.bytesWritten, 1000)
        XCTAssertEqual(try Data(contentsOf: url), payload.subdata(in: 1000..<2000))
    }

    func testPartialStartingElsewhereIsRefused() async throws {
        let payload = ScriptedURLProtocol.payload(4096)
        let recorder = Recorder()
        let port = try serveOnce(recorder: recorder) { _ in
            self.partial(payload.subdata(in: 0..<1000), start: 0, end: 999, total: 4096)
        }
        let (url, handle) = try tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let response = await BoundHTTPClient.downloadRange(
            request(port, start: 1000, end: 1999, total: 4096), file: handle, fileOffset: 0, limiter: nil)
        try handle.close()
        XCTAssertTrue(response.rangeMismatch)
        XCTAssertEqual(response.bytesWritten, 0)
        XCTAssertEqual(try Data(contentsOf: url).count, 0, "nothing may land at our offset")
    }

    func testHeaderValuesWithLineBreaksAreNotSmuggledAndLongValuesAreIntact() async throws {
        let recorder = Recorder()
        let port = try serveOnce(recorder: recorder) { _ in
            self.partial(Data(count: 10), start: 0, end: 9, total: 10)
        }
        let jwt = "Bearer " + String(repeating: "x", count: 6_000)
        let (url, handle) = try tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        _ = await BoundHTTPClient.downloadRange(
            request(port, start: 0, end: 9, total: 10,
                    headers: ["X-Evil": "a\r\nInjected: yes", "X-Jwt": jwt], ifRange: "\"e1\""),
            file: handle, fileOffset: 0, limiter: nil)
        try handle.close()
        let head = recorder.get()
        XCTAssertFalse(head.contains("Injected: yes"))
        XCTAssertTrue(head.contains("X-Jwt: \(jwt)\r\n"), "a long value must arrive whole")
        XCTAssertTrue(head.contains("If-Range: \"e1\"\r\n"))
    }

    // MARK: Pacing (ENG-7, ENG-8, PERF-1)

    func testUnlimitedChainIsDetectedWithoutAHop() async {
        let shared = RateLimiter(bytesPerSecond: 0)
        let task = RateLimiter(bytesPerSecond: 0, next: shared)
        XCTAssertTrue(task.isEffectivelyUnlimited)
        await shared.setRate(1_000)
        XCTAssertFalse(task.isEffectivelyUnlimited, "a limit anywhere down the chain counts")
        await shared.setRate(0)
        XCTAssertTrue(task.isEffectivelyUnlimited)
    }

    func testLimiterPacesOnTheMonotonicClock() async {
        let limiter = RateLimiter(bytesPerSecond: 1_000_000)
        let clock = ContinuousClock()
        let start = clock.now
        for _ in 0..<4 { await limiter.pace(50_000) }
        let elapsed = clock.now - start
        XCTAssertGreaterThanOrEqual(elapsed, .milliseconds(150))
        XCTAssertLessThan(elapsed, .seconds(3))
    }

    func testBoundPacingWaitReturnsPromptlyOnAbort() async throws {
        let limiter = RateLimiter(bytesPerSecond: 1)   // 64 KB at 1 B/s would block for hours
        let (url, handle) = try tempFile()
        defer { try? FileManager.default.removeItem(at: url); try? handle.close() }
        let ctx = BoundHTTPClient.TransferContext(handle: handle, limiter: limiter)
        let done = expectation(description: "pace returned")
        Thread {
            ctx.paceIfNeeded(64 * 1024, force: true)
            done.fulfill()
        }.start()
        try await Task.sleep(nanoseconds: 300_000_000)
        ctx.abort()
        await fulfillment(of: [done], timeout: 2)
    }

    // MARK: engines#5 — 206 without Content-Range

    private func partialWithoutRange(_ body: Data, declaredLength: Int? = nil) -> Data {
        var out = Data(("HTTP/1.1 206 Partial Content\r\nContent-Length: \(declaredLength ?? body.count)\r\n"
                        + "ETag: \"e1\"\r\nConnection: close\r\n\r\n").utf8)
        out.append(body)
        return out
    }

    func testPartialWithoutContentRangeIsTakenAsTheRequestedSpan() async throws {
        let payload = ScriptedURLProtocol.payload(4096)
        let port = try serveOnce(recorder: Recorder()) { _ in
            self.partialWithoutRange(payload.subdata(in: 1000..<2000))
        }
        let (url, handle) = try tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let response = await BoundHTTPClient.downloadRange(
            request(port, start: 1000, end: 1999, total: 4096), file: handle, fileOffset: 0, limiter: nil)
        try handle.close()
        XCTAssertEqual(response.curlCode, 0)
        XCTAssertFalse(response.hasContentRange)
        XCTAssertFalse(response.rangeTotalMismatch, "no header means no total to contradict")
        XCTAssertEqual(response.bytesWritten, 1000)
        XCTAssertEqual(try Data(contentsOf: url), payload.subdata(in: 1000..<2000))
    }

    func testPartialWithoutContentRangeOfAnotherLengthIsRefused() async throws {
        let payload = ScriptedURLProtocol.payload(4096)
        let port = try serveOnce(recorder: Recorder()) { _ in
            self.partialWithoutRange(payload.subdata(in: 0..<500))
        }
        let (url, handle) = try tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let response = await BoundHTTPClient.downloadRange(
            request(port, start: 1000, end: 1999, total: 4096), file: handle, fileOffset: 0, limiter: nil)
        try handle.close()
        XCTAssertTrue(response.rangeMismatch)
        XCTAssertEqual(try Data(contentsOf: url).count, 0)
    }

    // MARK: security#3 — every redirect hop is screened

    private func redirect(to location: String) -> Data {
        Data("HTTP/1.1 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    }

    private final class HopLog: @unchecked Sendable {
        private let lock = NSLock()
        private var hops: [URL] = []
        func add(_ url: URL) { lock.lock(); hops.append(url); lock.unlock() }
        var all: [URL] { lock.lock(); defer { lock.unlock() }; return hops }
    }

    func testRefusedHopIsNeverFetched() async throws {
        let port = try serveOnce(recorder: Recorder()) { _ in
            self.redirect(to: "http://metadata.internal.test/latest/")
        }
        let (url, handle) = try tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = HopLog()
        let response = await BoundHTTPClient.downloadRange(
            request(port, start: 0, end: 9, total: 10), file: handle, fileOffset: 0, limiter: nil,
            hopScreen: { hop, _ in log.add(hop); return false })
        try handle.close()
        XCTAssertTrue(response.redirectRefused)
        XCTAssertEqual(response.bytesWritten, 0)
        XCTAssertEqual(log.all.map(\.host), ["metadata.internal.test"])
    }

    func testAllowedHopIsFollowed() async throws {
        let payload = ScriptedURLProtocol.payload(10)
        let target = try serveOnce(recorder: Recorder()) { _ in
            self.partial(payload, start: 0, end: 9, total: 10)
        }
        let origin = try serveOnce(recorder: Recorder()) { _ in
            self.redirect(to: "http://127.0.0.1:\(target)/moved.bin")
        }
        let (url, handle) = try tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let log = HopLog()
        let response = await BoundHTTPClient.downloadRange(
            request(origin, start: 0, end: 9, total: 10), file: handle, fileOffset: 0, limiter: nil,
            hopScreen: { hop, from in
                log.add(hop)
                return from.port == Int(origin)   // screened against the ORIGINAL request
            })
        try handle.close()
        XCTAssertFalse(response.redirectRefused)
        XCTAssertEqual(response.curlCode, 0)
        XCTAssertEqual(try Data(contentsOf: url), payload)
        XCTAssertEqual(log.all.map(\.port), [Int(target)])
    }

    func testDefaultScreenRefusesAHopThatResolvesToLoopback() async throws {
        NetworkGuard.hostResolver = { $0 == "sneaky.example" ? ["127.0.0.1"] : nil }
        defer { NetworkGuard.useSystemHostResolver() }
        let port = try serveOnce(recorder: Recorder()) { _ in
            self.redirect(to: "http://sneaky.example:9/f.bin")
        }
        let (url, handle) = try tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let response = await BoundHTTPClient.downloadRange(
            request(port, start: 0, end: 9, total: 10), file: handle, fileOffset: 0, limiter: nil)
        try handle.close()
        XCTAssertTrue(response.redirectRefused, "a public-looking name resolving to 127.0.0.1 is refused")
    }
}
