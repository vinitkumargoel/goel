import XCTest
@testable import GoelCore

/// Direct unit tests for ``SegmentedTransfer`` — the per-download transfer
/// mechanics extracted out of ``HTTPEngine``. These drive the transfer WITHOUT
/// the actor, against the in-memory ``StubURLProtocol`` (defined in
/// `HTTPEngineTests.swift`), so the byte pumps, retry path, single-stream
/// fallback and resume gating are exercised in isolation. The end-to-end
/// `HTTPEngineTests` remain as integration coverage of the now-thin actor.
final class SegmentedTransferTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        StubURLProtocol.forceNext429s(0)
        StubURLProtocol.resetSeenUserAgents()
    }

    override func tearDown() {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        super.tearDown()
    }

    // MARK: Helpers

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func deterministicData(_ count: Int) -> Data {
        var data = Data(capacity: count)
        for i in 0..<count { data.append(UInt8((i * 31 + 7) & 0xFF)) }
        return data
    }

    private func plan(
        name: String,
        totalBytes: Int64?,
        acceptsRanges: Bool,
        segmentCount: Int,
        etag: String? = nil,
        lastModified: String? = nil,
        existingResume: Data? = nil
    ) -> TransferPlan {
        TransferPlan(
            url: URL(string: "https://example.test/\(name)")!,
            destination: tempDir.appendingPathComponent(name),
            totalBytes: totalBytes,
            acceptsRanges: acceptsRanges,
            etag: etag,
            lastModified: lastModified,
            existingResume: existingResume,
            segmentCount: segmentCount,
            session: makeSession(),
            settings: RequestSettings(userAgent: "GoelTest/1.0", maxAttempts: 10, retryInterval: 0),
            maxBytesPerSecond: 0,
            flushSize: 64 * 1024
        )
    }

    /// Runs the transfer, draining its progress stream concurrently, and returns
    /// the outcome plus the maximum connection count any progress tick reported.
    private func run(_ transfer: SegmentedTransfer) async throws -> (outcome: TransferOutcome, maxConnections: Int) {
        let stream = transfer.progress
        let consumer = Task { () -> Int in
            var maxConn = 0
            for await update in stream { maxConn = max(maxConn, update.connectionCount) }
            return maxConn
        }
        let outcome = try await transfer.run()
        let maxConn = await consumer.value
        return (outcome, maxConn)
    }

    // MARK: Segmented download under forced 429 rate-limiting

    func testSegmentedDownloadCompletesUnderForced429s() async throws {
        let payload = deterministicData(300 * 1024)
        StubURLProtocol.set(.init(
            data: payload, supportsRanges: true, sendContentLength: true,
            etag: "\"rl\"", chunkSize: 32 * 1024, chunkDelayMicros: 0
        ))
        // Force the first 6 ranged GETs to 429 (Retry-After: 0 keeps it fast). The
        // governor shrinks toward the server's ceiling and segments retry through.
        StubURLProtocol.forceNext429s(6)

        let p = plan(name: "seg429.bin", totalBytes: Int64(payload.count), acceptsRanges: true, segmentCount: 8, etag: "\"rl\"")
        let (outcome, maxConn) = try await run(SegmentedTransfer(plan: p))

        XCTAssertEqual(outcome.bytesWritten, Int64(payload.count), "all bytes must land despite retried segments")
        XCTAssertGreaterThan(outcome.usedSegments, 1, "a 300 KB file should be segmented")
        XCTAssertGreaterThan(maxConn, 1, "segmented progress should report multiple connections")
        let written = try Data(contentsOf: p.destination)
        XCTAssertEqual(written, payload, "stitched file must equal the source bytes")
        XCTAssertGreaterThan(StubURLProtocol.seenUserAgents().count, 6, "the 6 forced 429s must have caused retries")
    }

    // MARK: Single-stream fallback when ranges unsupported

    func testSingleStreamFallbackWhenRangesUnsupported() async throws {
        let payload = deterministicData(200 * 1024)
        StubURLProtocol.set(.init(
            data: payload, supportsRanges: false, sendContentLength: true,
            etag: nil, chunkSize: 16 * 1024, chunkDelayMicros: 0
        ))
        let p = plan(name: "single.bin", totalBytes: Int64(payload.count), acceptsRanges: false, segmentCount: 8)
        let (outcome, maxConn) = try await run(SegmentedTransfer(plan: p))

        XCTAssertEqual(outcome.usedSegments, 1, "no range support must fall back to a single connection")
        XCTAssertNil(outcome.resumeData, "a single stream produces no resume cursor")
        XCTAssertLessThanOrEqual(maxConn, 1, "the fallback must never open more than one connection")
        let written = try Data(contentsOf: p.destination)
        XCTAssertEqual(written, payload)
    }

    func testSingleStreamWhenTotalUnknown() async throws {
        let payload = deterministicData(180 * 1024)
        StubURLProtocol.set(.init(
            data: payload, supportsRanges: false, sendContentLength: false,
            etag: nil, chunkSize: 16 * 1024, chunkDelayMicros: 0
        ))
        // totalBytes == nil forces the single-stream path even if ranges were
        // (nominally) accepted.
        let p = plan(name: "unknown.bin", totalBytes: nil, acceptsRanges: true, segmentCount: 8)
        let (outcome, _) = try await run(SegmentedTransfer(plan: p))

        XCTAssertEqual(outcome.usedSegments, 1)
        XCTAssertEqual(outcome.bytesWritten, Int64(payload.count))
        let written = try Data(contentsOf: p.destination)
        XCTAssertEqual(written, payload)
    }

    // MARK: Resume continue vs restart

    func testResumeContinueSkipsStoredRangesButRestartRefetchesAll() async throws {
        let payload = deterministicData(256 * 1024)
        StubURLProtocol.set(.init(
            data: payload, supportsRanges: true, sendContentLength: true,
            etag: "\"v1\"", chunkSize: 64 * 1024, chunkDelayMicros: 0
        ))

        // A cursor for the exact ranges the transfer would compute, with the first
        // three of four segments already complete and the last untouched.
        let ranges = SegmentedTransfer.makeRanges(total: Int64(payload.count), count: 4)
        XCTAssertEqual(ranges.count, 4)
        let segLen = ranges[0].end - ranges[0].start + 1
        let cursor = SegmentedTransfer.ResumeCursor(
            etag: "\"v1\"", lastModified: nil, totalBytes: Int64(payload.count),
            ranges: ranges, completed: [segLen, segLen, segLen, 0]
        )
        let cursorData = try JSONEncoder().encode(cursor)

        // --- Continue: matching ETag, stored bytes already on disk ---
        StubURLProtocol.resetSeenUserAgents()
        let continuePlan = plan(name: "resume-continue.bin", totalBytes: Int64(payload.count),
                                acceptsRanges: true, segmentCount: 4, etag: "\"v1\"", existingResume: cursorData)
        // Pre-write the complete payload so the three "done" segments are valid.
        try payload.write(to: continuePlan.destination)
        let continueOutcome = try await run(SegmentedTransfer(plan: continuePlan)).outcome
        let continueRequests = StubURLProtocol.seenUserAgents().count
        XCTAssertEqual(try Data(contentsOf: continuePlan.destination), payload, "continue must produce the full file")
        XCTAssertEqual(continueOutcome.bytesWritten, Int64(payload.count))

        // --- Restart: mismatched ETag must discard the cursor and refetch all ---
        StubURLProtocol.resetSeenUserAgents()
        let restartPlan = plan(name: "resume-restart.bin", totalBytes: Int64(payload.count),
                               acceptsRanges: true, segmentCount: 4, etag: "\"v2\"", existingResume: cursorData)
        let restartOutcome = try await run(SegmentedTransfer(plan: restartPlan)).outcome
        let restartRequests = StubURLProtocol.seenUserAgents().count
        XCTAssertEqual(try Data(contentsOf: restartPlan.destination), payload, "restart must produce the full file")
        XCTAssertEqual(restartOutcome.usedSegments, 4)

        // The observable distinction: continue fetches ONLY the one missing
        // segment; restart re-requests every segment.
        XCTAssertEqual(continueRequests, 1,
                       "matching-ETag resume must issue exactly one ranged GET for the single incomplete segment")
        XCTAssertEqual(restartRequests, 4, "a restart issues one ranged GET per segment")
    }

    // MARK: Pure range math

    func testMakeRangesPartitionsExactly() {
        let ranges = SegmentedTransfer.makeRanges(total: 1000, count: 3)
        XCTAssertEqual(ranges.count, 3)
        XCTAssertEqual(ranges[0].start, 0)
        XCTAssertEqual(ranges[0].end, 332)      // base = 1000 / 3 = 333
        XCTAssertEqual(ranges[1].start, 333)
        XCTAssertEqual(ranges[1].end, 665)
        XCTAssertEqual(ranges[2].start, 666)
        XCTAssertEqual(ranges[2].end, 999)      // last segment takes the remainder
        // Contiguous, gap-free, covering [0, total).
        for i in 1..<ranges.count { XCTAssertEqual(ranges[i].start, ranges[i - 1].end + 1) }
    }

    func testMakeRangesEdgeCases() {
        XCTAssertTrue(SegmentedTransfer.makeRanges(total: 0, count: 4).isEmpty, "zero-byte file fetches nothing")
        let one = SegmentedTransfer.makeRanges(total: 500, count: 0)
        XCTAssertEqual(one.count, 1, "count 0 collapses to a single full range")
        XCTAssertEqual(one[0].start, 0)
        XCTAssertEqual(one[0].end, 499)
    }

    // MARK: Cursor encode / decode + validators

    func testResumeCursorRoundTrips() throws {
        let cursor = SegmentedTransfer.ResumeCursor(
            etag: "\"abc\"", lastModified: "Mon, 01 Jan 2024 00:00:00 GMT", totalBytes: 100,
            ranges: [.init(start: 0, end: 49), .init(start: 50, end: 99)], completed: [10, 0]
        )
        let data = try JSONEncoder().encode(cursor)
        let back = try JSONDecoder().decode(SegmentedTransfer.ResumeCursor.self, from: data)
        XCTAssertEqual(back.etag, cursor.etag)
        XCTAssertEqual(back.lastModified, cursor.lastModified)
        XCTAssertEqual(back.totalBytes, cursor.totalBytes)
        XCTAssertEqual(back.completed, cursor.completed)
        XCTAssertEqual(back.ranges.map(\.start), [0, 50])
        XCTAssertEqual(back.ranges.map(\.end), [49, 99])
    }

    func testValidatorsGateResume() {
        // No validators on either side -> cannot verify the remote -> restart.
        XCTAssertFalse(SegmentedTransfer.validatorsAllowResume(
            cursorETag: nil, cursorLastModified: nil, probeETag: nil, probeLastModified: nil))
        // ETag drives the decision when present.
        XCTAssertTrue(SegmentedTransfer.validatorsAllowResume(
            cursorETag: "v1", cursorLastModified: nil, probeETag: "v1", probeLastModified: nil))
        XCTAssertFalse(SegmentedTransfer.validatorsAllowResume(
            cursorETag: "v1", cursorLastModified: nil, probeETag: "v2", probeLastModified: nil))
        // Falls back to Last-Modified when ETag is absent.
        XCTAssertTrue(SegmentedTransfer.validatorsAllowResume(
            cursorETag: nil, cursorLastModified: "Mon, 01 Jan 2024", probeETag: nil, probeLastModified: "Mon, 01 Jan 2024"))
    }
}
