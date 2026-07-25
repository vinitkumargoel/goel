import Foundation
import Synchronization
import Testing
#if canImport(Darwin)
import Darwin
#endif
@testable import Goel

// MARK: - Tags

extension Tag {
    /// Tests that need `Scripts/ios/range-server.py` running on :8099 (and, for the
    /// non-resumable case, a second instance with `--no-ranges` on :8100). They move real bytes
    /// and take a second or two; tag them so they can be excluded when that matters.
    @Tag static var network: Self
}

/// True when something is listening on `port` on the loopback interface.
///
/// A synchronous connect rather than a `URLSession` round trip so it can be used from
/// `.enabled(if:)`, which is evaluated before the test body runs. Without this the end-to-end
/// tests would fail — rather than skip — on any machine where the harness is not running, and a
/// suite that is red for an environmental reason quickly becomes a suite nobody reads.
func goelRangeServerIsReachable(port: UInt16 = 8099) -> Bool {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return result == 0
}

// MARK: - SegmentMathTests

/// T05's arithmetic, and T05's actual gate.
///
/// The split is the classic place a segmented downloader ships a bug that nothing catches: the
/// file comes out the right length, the progress bar reaches 100 %, and one byte in the middle is
/// wrong. `bytes=0-99` is one hundred bytes, and a size that divides evenly by six will hide an
/// off-by-one that a size ending in `…199` exposes immediately.
@Suite("Segment math and the real transfer")
struct SegmentMathTests {

    // MARK: - Split arithmetic

    /// Every property that matters, checked at once: the union is exactly the input range, there
    /// is no gap, no overlap, and no zero-length segment.
    static func assertExactCover(
        _ segments: [ClosedRange<Int64>],
        covers range: ClosedRange<Int64>,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(!segments.isEmpty, sourceLocation: sourceLocation)
        #expect(segments.first?.lowerBound == range.lowerBound, sourceLocation: sourceLocation)
        #expect(segments.last?.upperBound == range.upperBound, sourceLocation: sourceLocation)

        for segment in segments {
            #expect(segment.upperBound >= segment.lowerBound, sourceLocation: sourceLocation)
            #expect(SegmentPlan.length(of: segment) > 0, sourceLocation: sourceLocation)
        }
        for (left, right) in zip(segments, segments.dropFirst()) {
            // Adjacent and non-overlapping: the next segment starts on the byte after this one
            // ends. Anything else is either a hole or a double-download.
            #expect(right.lowerBound == left.upperBound + 1, sourceLocation: sourceLocation)
        }
        let total = segments.reduce(Int64(0)) { $0 + SegmentPlan.length(of: $1) }
        #expect(total == SegmentPlan.length(of: range), sourceLocation: sourceLocation)
    }

    @Test("209,715,199 bytes over six connections covers 0…size-1 exactly")
    func splitWithARemainder() {
        let size: Int64 = 209_715_199  // deliberately not a multiple of 6
        let segments = SegmentPlan.split(0...(size - 1), into: 6)

        #expect(segments.count == 6)
        Self.assertExactCover(segments, covers: 0...(size - 1))

        // 209_715_199 = 6 × 34_952_533 + 1, so exactly one segment is a byte longer and it is the
        // first — the remainder is spread over the leading segments, never dumped on the last.
        #expect(SegmentPlan.length(of: segments[0]) == 34_952_534)
        #expect(SegmentPlan.length(of: segments[1]) == 34_952_533)
        #expect(SegmentPlan.length(of: segments[5]) == 34_952_533)
    }

    @Test("A remainder of five spreads one byte over the first five segments")
    func splitSpreadsTheRemainder() {
        let segments = SegmentPlan.split(0...(6_005 - 1), into: 6)
        Self.assertExactCover(segments, covers: 0...6_004)
        #expect(segments.map { SegmentPlan.length(of: $0) } == [1_001, 1_001, 1_001, 1_001, 1_001, 1_000])
    }

    @Test("Splitting never produces a zero-length segment, even asking for more parts than bytes")
    func splitNeverProducesEmptySegments() {
        let segments = SegmentPlan.split(0...2, into: 6)
        #expect(segments.count == 3)
        Self.assertExactCover(segments, covers: 0...2)
        #expect(SegmentPlan.split(100...100, into: 6) == [100...100])
        #expect(SegmentPlan.split(0...0, into: 1) == [0...0])
    }

    @Test("A split that does not start at zero still covers exactly")
    func splitOfAnOffsetRange() {
        let segments = SegmentPlan.split(1_780...5_999, into: 4)
        Self.assertExactCover(segments, covers: 1_780...5_999)
        #expect(segments.count == 4)
    }

    // MARK: - Connection count

    @Test("Below the 8 MB threshold a download gets one connection")
    func belowThresholdIsASingleStream() {
        let tuning = EngineTuning(maxConnections: 6)
        #expect(SegmentPlan.segmentationThreshold == 8 * 1024 * 1024)
        #expect(SegmentPlan.connectionCount(tuning: tuning, totalBytes: 8_388_607, supportsResume: true) == 1)
        #expect(SegmentPlan.connectionCount(tuning: tuning, totalBytes: 8_388_608, supportsResume: true) == 6)
    }

    @Test("maxConnections = 2 yields exactly two")
    func connectionCountHonoursTheCap() {
        let tuning = EngineTuning(maxConnections: 2)
        #expect(SegmentPlan.connectionCount(tuning: tuning, totalBytes: 200_000_000, supportsResume: true) == 2)

        let plan = SegmentPlan.plan(gaps: [0...199_999_999], connections: 2, isSequential: false)
        #expect(plan.count == 2)
        Self.assertExactCover(plan, covers: 0...199_999_999)
    }

    @Test("The traffic profile is a ceiling as well as a default")
    func profileCapsConnections() {
        let conservative = EngineTuning(trafficProfile: .conservative, maxConnections: 8)
        #expect(SegmentPlan.connectionCount(tuning: conservative, totalBytes: 200_000_000, supportsResume: true) == 2)

        let aggressive = EngineTuning(trafficProfile: .aggressive, maxConnections: 8)
        #expect(SegmentPlan.connectionCount(tuning: aggressive, totalBytes: 200_000_000, supportsResume: true) == 8)

        #expect(SegmentPlan.defaultConnectionCount == 6)
        #expect(EngineTuning.default.maxConnections == SegmentPlan.defaultConnectionCount)
    }

    @Test("No ranges and no known length both mean a single stream")
    func unsegmentableDownloads() {
        let tuning = EngineTuning(maxConnections: 6)
        #expect(SegmentPlan.connectionCount(tuning: tuning, totalBytes: 200_000_000, supportsResume: false) == 1)
        #expect(SegmentPlan.connectionCount(tuning: tuning, totalBytes: nil, supportsResume: true) == 1)
    }

    // MARK: - Planning around holes

    @Test("A resumed download plans only the holes")
    func planFillsGapsOnly() {
        let gaps = HandoffState.gaps(in: [0...1_023, 4_096...8_191], total: 16_384)
        #expect(gaps == [1_024...4_095, 8_192...16_383])

        let plan = SegmentPlan.plan(gaps: gaps, connections: 6, isSequential: false)
        let covered = plan.reduce(Int64(0)) { $0 + SegmentPlan.length(of: $1) }
        #expect(covered == 3_072 + 8_192)
        // Nothing planned may overlap what is already on disk.
        #expect(plan.allSatisfy { $0.lowerBound >= 1_024 })
        #expect(plan.allSatisfy { !(1_024...4_095).overlaps($0) || $0.upperBound <= 4_095 })
    }

    // MARK: - Sequential mode

    @Test("Sequential mode lays the file out as ordered blocks with no gap between them")
    func sequentialBlocksAreOrderedAndContiguous() {
        let total: Int64 = 209_715_199
        let plan = SegmentPlan.plan(gaps: [0...(total - 1)], connections: 6, isSequential: true)

        Self.assertExactCover(plan, covers: 0...(total - 1))
        #expect(plan.count > 6, "sequential mode must still have work for every connection")
        #expect(plan.allSatisfy { SegmentPlan.length(of: $0) <= SegmentPlan.sequentialBlockSize(forTotal: total) })
    }

    /// The property T10 depends on: with every worker always claiming the **lowest** unclaimed
    /// block, the set of blocks in flight is the run immediately after the completed prefix. No
    /// connection ever opens ahead of a gap, so bytes `0…n` stay contiguous while the rest arrives.
    @Test("Sequential mode never opens a connection past a gap")
    func sequentialClaimsNeverJumpAGap() {
        var pending = SegmentPlan.plan(gaps: [0...(64 * 1024 * 1024 - 1)], connections: 6, isSequential: true)
        var completed: [ClosedRange<Int64>] = []

        // Ten rounds of: six workers each take the lowest remaining block, then finish them.
        for _ in 0..<10 {
            var claimed: [ClosedRange<Int64>] = []
            for _ in 0..<6 {
                guard let index = pending.indices.min(by: { pending[$0].lowerBound < pending[$1].lowerBound })
                else { break }
                claimed.append(pending.remove(at: index))
            }
            guard !claimed.isEmpty else { break }

            // Everything in flight, together with everything already done, is one unbroken run
            // from byte 0 — which is precisely "no segment starts past a gap".
            let union = HandoffState.merged(completed + claimed)
            #expect(union.count == 1, "in-flight blocks must be contiguous with the completed prefix")
            #expect(union.first?.lowerBound == 0)

            completed = HandoffState.merged(completed + claimed)
        }

        // And what is finished is always a prefix, never an island.
        #expect(completed.count == 1)
        #expect(HandoffState.contiguousPrefix(of: completed) == SegmentPlan.length(of: completed[0]))
    }

    @Test("Parallel mode does the opposite — it claims across the whole file at once")
    func parallelModeSpansTheFile() {
        let plan = SegmentPlan.plan(gaps: [0...(64 * 1024 * 1024 - 1)], connections: 6, isSequential: false)
        #expect(plan.count == 6)
        // The sixth connection starts five sixths of the way in; contiguity is explicitly not a
        // promise here, which is why `isSequential` exists at all.
        #expect(plan[5].lowerBound > 0)
    }

    // MARK: - Backoff

    @Test("Backoff is 0.5s, 1s, 2s with a small deterministic spread")
    func backoffGrowsExponentially() {
        for seed in 0..<8 {
            let delays = (1...3).map { SegmentPlan.backoffDelay(attempt: $0, seed: seed) }
            #expect(delays[0] >= 0.5 && delays[0] < 0.6)
            #expect(delays[1] >= 1.0 && delays[1] < 1.1)
            #expect(delays[2] >= 2.0 && delays[2] < 2.1)
            #expect(delays[0] < delays[1] && delays[1] < delays[2])
        }
        // Deterministic, so a failing retry test is reproducible; different per segment, so six
        // connections dropped by the same Wi-Fi blip do not all retry on the same millisecond.
        #expect(SegmentPlan.backoffDelay(attempt: 1, seed: 3) == SegmentPlan.backoffDelay(attempt: 1, seed: 3))
        #expect(SegmentPlan.backoffDelay(attempt: 1, seed: 3) != SegmentPlan.backoffDelay(attempt: 1, seed: 4))
        // Bounded: a segment that keeps failing must not wait an hour.
        #expect(SegmentPlan.backoffDelay(attempt: 99, seed: 0) < 20)
    }

    // MARK: - Token bucket

    @Test("The token bucket releases the configured rate over a simulated interval")
    func tokenBucketReleasesTheConfiguredRate() async {
        // A fake clock: the bucket's arithmetic is tested without anything actually sleeping.
        let clock = TestClock()
        let bucket = TokenBucket(rate: 1_000, clock: clock.read)

        // One second of burst is available immediately.
        #expect(await bucket.reserve(1_000) == 0)

        // The next thousand bytes have not been earned yet — exactly one second of debt.
        let wait = await bucket.reserve(1_000)
        #expect(abs(wait - 1.0) < 0.001)

        // After two simulated seconds the debt is cleared and a fresh second is available.
        clock.advance(by: 2)
        #expect(await bucket.reserve(1_000) == 0)

        // Over a long window the average is the configured rate, not a multiple of it: this is
        // what makes the cap hold across six connections drawing on one bucket.
        clock.advance(by: 10)
        var granted = 0
        while await bucket.reserve(100) == 0 { granted += 100 }
        #expect(granted <= 1_100, "burst must be bounded by roughly one second of the rate")
    }

    @Test("An unlimited bucket never asks anyone to wait")
    func unlimitedBucketNeverWaits() async {
        let bucket = TokenBucket(rate: nil, clock: TestClock().read)
        for _ in 0..<100 {
            #expect(await bucket.reserve(10 * 1024 * 1024) == 0)
        }
    }

    @Test("Changing the rate applies to a bucket that is already in use")
    func rateChangeAppliesImmediately() async {
        let clock = TestClock()
        let bucket = TokenBucket(rate: nil, clock: clock.read)
        #expect(await bucket.reserve(1_000_000) == 0)

        await bucket.setRate(1_000)
        #expect(await bucket.currentRate() == 1_000)
        // The burst is refilled to the new rate's ceiling, then the cap bites.
        _ = await bucket.reserve(1_000)
        #expect(await bucket.reserve(2_000) > 0)
    }

    // MARK: - Cellular policy

    @Test("Cellular parks a download rather than failing it")
    func cellularPolicy() {
        let strict = EngineTuning(allowCellular: false)
        #expect(URLSessionTransferEngine.policyStatus(isCellular: true, isExpensive: false, tuning: strict) == .waitingForWiFi)
        #expect(URLSessionTransferEngine.policyStatus(isCellular: false, isExpensive: true, tuning: strict) == .waitingForWiFi)
        #expect(URLSessionTransferEngine.policyStatus(isCellular: false, isExpensive: false, tuning: strict) == nil)

        let permissive = EngineTuning(allowCellular: true)
        #expect(URLSessionTransferEngine.policyStatus(isCellular: true, isExpensive: true, tuning: permissive) == nil)
    }

    // MARK: - Response validation

    @Test("A 200 in answer to a ranged request is treated as the file having changed")
    func rangedRequestAnsweredWithTwoHundred() throws {
        let url = try #require(URL(string: "https://example.com/f.bin"))
        let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil))

        // Resuming from byte 1 000 and getting the whole file back means `If-Range` did not match.
        #expect(throws: TransferError.remoteFileChanged) {
            try URLSessionTransferEngine.validate(response, usesRange: true, coversWholeFile: false)
        }
        // The same 200 is fine when the "range" was the whole file from byte zero.
        #expect(throws: Never.self) {
            try URLSessionTransferEngine.validate(response, usesRange: true, coversWholeFile: true)
        }
    }

    @Test("416 means the remote file changed; 404 means it is gone")
    func statusCodeMapping() throws {
        let url = try #require(URL(string: "https://example.com/f.bin"))
        func response(_ code: Int) throws -> HTTPURLResponse {
            try #require(HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil))
        }
        #expect(throws: TransferError.remoteFileChanged) {
            try URLSessionTransferEngine.validate(try response(416), usesRange: true, coversWholeFile: false)
        }
        #expect(throws: TransferError.notFound) {
            try URLSessionTransferEngine.validate(try response(404), usesRange: true, coversWholeFile: false)
        }
        #expect(throws: Never.self) {
            try URLSessionTransferEngine.validate(try response(206), usesRange: true, coversWholeFile: false)
        }
        #expect(throws: (any Error).self) {
            try URLSessionTransferEngine.validate(try response(500), usesRange: false, coversWholeFile: true)
        }
    }

    // MARK: - Filenames and the sandbox

    @Test("A filename from Content-Disposition can never escape the container")
    func filenamesAreSanitized() throws {
        let url = try #require(URL(string: "https://example.com/downloads/report.pdf"))

        #expect(URLSessionTransferEngine.filename(from: "attachment; filename=\"invoice.pdf\"", url: url) == "invoice.pdf")
        #expect(URLSessionTransferEngine.filename(from: "attachment; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf", url: url) == "résumé.pdf")
        #expect(URLSessionTransferEngine.filename(from: nil, url: url) == "report.pdf")

        // The whole reason `FileStore` owns this.
        #expect(URLSessionTransferEngine.filename(from: "attachment; filename=\"../../Library/Preferences/x.plist\"", url: url) == "x.plist")
        #expect(FileStore.sanitizedFilename("../../etc/passwd") == "passwd")
        #expect(FileStore.sanitizedFilename("..") == "download")
        #expect(FileStore.sanitizedFilename("") == "download")
        #expect(FileStore.sanitizedFilename("a/b\\c.bin") == "c.bin")
    }

    @Test("Containment is checked on path components, not string prefixes")
    func containment() {
        let root = URL(filePath: "/tmp/goel-root", directoryHint: .isDirectory)
        #expect(FileStore.isContained(URL(filePath: "/tmp/goel-root/a.bin"), in: root))
        #expect(FileStore.isContained(URL(filePath: "/tmp/goel-root/sub/a.bin"), in: root))
        #expect(!FileStore.isContained(URL(filePath: "/tmp/goel-rootlet/a.bin"), in: root))
        #expect(!FileStore.isContained(URL(filePath: "/tmp/goel-root"), in: root))
        #expect(!FileStore.isContained(URL(filePath: "/tmp/goel-root/../other/a.bin"), in: root))
    }

    @Test("A save directory outside the container is ignored, not honoured")
    func destinationStaysInTheContainer() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "goel-store-\(UUID().uuidString)", directoryHint: .isDirectory)
        let store = FileStore(root: root)

        let inside = try store.destinationURL(filename: "a.bin", subdirectory: "Goel°/Linux")
        #expect(FileStore.isContained(inside, in: root))
        #expect(inside.lastPathComponent == "a.bin")

        let escaped = try store.destinationURL(filename: "a.bin", subdirectory: "/etc")
        #expect(FileStore.isContained(escaped, in: root))
        #expect(escaped == root.appending(path: "a.bin", directoryHint: .notDirectory))

        let traversal = try store.destinationURL(filename: "../../a.bin", subdirectory: nil)
        #expect(FileStore.isContained(traversal, in: root))
    }

    @Test("A checksum sidecar is parsed; an HTML error page is not")
    func checksumSidecarParsing() {
        let digest = "e5ef1b4a8707375a4b43e8c6c58fc60529f69b16b516c75b39b822dd5d943806"
        #expect(FileStore.parseChecksumSidecar(digest + "\n") == digest)
        #expect(FileStore.parseChecksumSidecar("\(digest)  test-8mb.bin\n") == digest)
        #expect(FileStore.parseChecksumSidecar("<html><body>404 Not Found</body></html>") == nil)
        #expect(FileStore.parseChecksumSidecar("deadbeef") == nil)
    }

    // MARK: - The real thing

    /// **T05's actual gate.**
    ///
    /// Everything above is arithmetic. This moves eight megabytes over a real socket, through the
    /// real segmenter, into a real sparse file, and compares the SHA-256 of the result against the
    /// digest of the fixture. A segmenter with an off-by-one passes every test above this line and
    /// fails this one.
    ///
    /// Run `python3 Scripts/ios/range-server.py` first; the test skips rather than fails without it.
    @Test(
        "8 MB downloads end to end and the SHA-256 matches",
        .tags(.network),
        .enabled(if: goelRangeServerIsReachable(), "range-server.py is not running on :8099"),
        .timeLimit(.minutes(2))
    )
    func eightMegabyteDownloadMatchesItsChecksum() async throws {
        let expected = "e5ef1b4a8707375a4b43e8c6c58fc60529f69b16b516c75b39b822dd5d943806"
        let harness = try TransferHarness()
        defer { harness.cleanUp() }

        let result = try await harness.run(
            url: #require(URL(string: "http://localhost:8099/test-8mb.bin")),
            filename: "test-8mb.bin"
        )

        #expect(result.status == .completed)
        #expect(result.fileURL?.lastPathComponent == "test-8mb.bin")
        let fileURL = try #require(result.fileURL)
        #expect(try FileStore.sha256Hex(ofFileAt: fileURL) == expected)

        let size = try FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int64
        #expect(size == 8_388_608)

        // Eight megabytes is exactly the threshold, so this went out over six connections.
        #expect(result.supportsResume)
        #expect(result.maxSegmentsSeen > 1, "an 8 MB file at the threshold must be segmented")
        // The sidecar exists, so verification is claimed — and only because it was performed.
        #expect(await harness.engine.checksumVerified(result.id))
    }

    /// The `--no-ranges` path. PRD §4.1: when the server cannot resume, the app says so up front
    /// rather than failing at 99 % — and still finishes the download.
    @Test(
        "A server without Accept-Ranges gets one stream, supportsResume == false, and still completes",
        .tags(.network),
        .enabled(if: goelRangeServerIsReachable(port: 8100), "range-server.py --no-ranges is not running on :8100"),
        .timeLimit(.minutes(2))
    )
    func nonResumableServerStillCompletes() async throws {
        let expected = "e5ef1b4a8707375a4b43e8c6c58fc60529f69b16b516c75b39b822dd5d943806"
        let harness = try TransferHarness()
        defer { harness.cleanUp() }

        let result = try await harness.run(
            url: #require(URL(string: "http://localhost:8100/test-8mb.bin")),
            filename: "test-8mb.bin"
        )

        #expect(result.status == .completed)
        #expect(!result.supportsResume)
        #expect(result.maxSegmentsSeen == 1, "no ranges means exactly one connection")
        let fileURL = try #require(result.fileURL)
        #expect(try FileStore.sha256Hex(ofFileAt: fileURL) == expected)
    }

    /// Sequential mode over the wire, and the honest statement of what it promises.
    ///
    /// It does **not** promise that no byte is ever downloaded out of order — that would mean one
    /// connection and no speed advantage at all. It promises that the *playable watermark* (the
    /// contiguous prefix) only ever moves forward, and that the bytes running ahead of it are
    /// confined to the handful of blocks currently in flight rather than scattered across the
    /// whole file. That is exactly what T10 needs to hand a growing file to `AVPlayer`.
    @Test(
        "Sequential mode keeps a monotonic playable prefix with a bounded lead",
        .tags(.network),
        .enabled(if: goelRangeServerIsReachable(), "range-server.py is not running on :8099"),
        .timeLimit(.minutes(2))
    )
    func sequentialDownloadStaysPlayable() async throws {
        let expected = "e5ef1b4a8707375a4b43e8c6c58fc60529f69b16b516c75b39b822dd5d943806"
        let total: Int64 = 8_388_608
        let harness = try TransferHarness()
        defer { harness.cleanUp() }

        let sequential = try await harness.run(
            url: #require(URL(string: "http://localhost:8099/test-8mb.bin")),
            filename: "test-8mb-seq.bin",
            isSequential: true
        )

        #expect(sequential.status == .completed)
        #expect(!sequential.prefixWentBackwards, "the playable watermark must never move backwards")
        #expect(sequential.finalPrefix == total)

        // Nothing may run more than the in-flight block window ahead of the watermark.
        let window = SegmentPlan.sequentialBlockSize(forTotal: total) * Int64(SegmentPlan.defaultConnectionCount)
        #expect(sequential.maxLagBytes <= window)

        let fileURL = try #require(sequential.fileURL)
        #expect(try FileStore.sha256Hex(ofFileAt: fileURL) == expected)

        // The contrast that shows the mode is doing something: a parallel download of the same
        // file leaves far more of it stranded behind holes at some point in its life.
        let parallel = try await harness.run(
            url: #require(URL(string: "http://localhost:8099/test-8mb.bin")),
            filename: "test-8mb-par.bin",
            isSequential: false
        )
        #expect(parallel.status == .completed)
        #expect(parallel.maxLagBytes > sequential.maxLagBytes)
    }

    @Test(
        "A missing file fails with a sentence a person can read, not an error code",
        .tags(.network),
        .enabled(if: goelRangeServerIsReachable(), "range-server.py is not running on :8099"),
        .timeLimit(.minutes(1))
    )
    func missingFileFailsCleanly() async throws {
        let harness = try TransferHarness()
        defer { harness.cleanUp() }
        let engine = harness.engine
        let url = try #require(URL(string: "http://localhost:8099/does-not-exist.bin"))

        await #expect(throws: TransferError.notFound) {
            try await engine.probe(url)
        }
    }
}

// MARK: - TestClock

/// A hand-cranked monotonic clock, so the token bucket's arithmetic can be tested in microseconds
/// instead of seconds. `Mutex`-backed rather than actor-backed because ``TokenBucket`` reads it
/// synchronously.
final class TestClock: Sendable {
    private let seconds = Mutex<Double>(0)

    var read: @Sendable () -> Double {
        { self.seconds.withLock { $0 } }
    }

    func advance(by interval: Double) {
        seconds.withLock { $0 += interval }
    }
}

// MARK: - TransferHarness

/// Drives a real ``URLSessionTransferEngine`` into a throwaway container and collects everything
/// the event stream said along the way.
final class TransferHarness: Sendable {

    struct Result: Sendable {
        var id: UUID
        var status: Download.Status
        var fileURL: URL?
        var message: String?
        var supportsResume: Bool
        var maxSegmentsSeen: Int
        /// The largest distance ever observed between the received byte count and the contiguous
        /// prefix — how far the playable watermark ever trailed the bytes on disk.
        var maxLagBytes: Int64
        /// The playable watermark must only ever move forward. If this is `true`, T10 would have
        /// to seek an `AVPlayer` backwards mid-playback.
        var prefixWentBackwards: Bool
        var finalPrefix: Int64
    }

    let root: URL
    let engine: URLSessionTransferEngine

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "goel-harness-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        engine = URLSessionTransferEngine(
            fileStore: FileStore(root: root),
            tuning: EngineTuning(maxConnections: 6, allowCellular: true),
            monitorsNetworkPath: false,
            // No background session: this harness is not an app, and there is nothing to relaunch.
            backgroundCoordinator: nil
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }

    func run(url: URL, filename: String, isSequential: Bool = false) async throws -> Result {
        let download = Download(
            url: url,
            filename: filename,
            saveDirectory: "",
            kind: Download.Kind.infer(from: url),
            isSequential: isSequential
        )
        let events = engine.events
        try await engine.start(download)

        var maxSegments = 0
        var maxLag: Int64 = 0
        var lastPrefix: Int64 = 0
        var wentBackwards = false

        for await event in events where event.downloadID == download.id {
            switch event {
            case let .progress(_, received, total, _, segments):
                maxSegments = max(maxSegments, segments.count)
                var snapshot = download
                snapshot.segments = segments
                snapshot.receivedBytes = received
                snapshot.totalBytes = total
                let prefix = snapshot.contiguousPrefix
                maxLag = max(maxLag, received - prefix)
                if prefix < lastPrefix { wentBackwards = true }
                lastPrefix = max(lastPrefix, prefix)
            case .statusChanged:
                continue
            case let .completed(_, fileURL):
                return Result(
                    id: download.id,
                    status: .completed,
                    fileURL: fileURL,
                    message: nil,
                    supportsResume: await engine.probeSupportsResume(url),
                    maxSegmentsSeen: maxSegments,
                    maxLagBytes: maxLag,
                    prefixWentBackwards: wentBackwards,
                    finalPrefix: lastPrefix
                )
            case let .failed(_, message):
                return Result(
                    id: download.id,
                    status: .failed,
                    fileURL: nil,
                    message: message,
                    supportsResume: false,
                    maxSegmentsSeen: maxSegments,
                    maxLagBytes: maxLag,
                    prefixWentBackwards: wentBackwards,
                    finalPrefix: lastPrefix
                )
            }
        }
        throw TransferError.network("The event stream ended without a terminal event.")
    }
}

extension URLSessionTransferEngine {
    /// Convenience for the harness: re-probe and report only the resumability flag.
    func probeSupportsResume(_ url: URL) async -> Bool {
        ((try? await probe(url))?.supportsResume) ?? false
    }
}
