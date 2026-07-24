import Foundation
import Testing
@testable import Goel

/// The domain type's arithmetic, its wire format, and the three places it is easy to ship a
/// `NaN`, an `inf`, or a 31-year date offset without noticing.
@Suite("Download model")
struct ModelTests {

    // MARK: - Fixtures

    /// A fixed instant so encode/decode round trips are bit-exact rather than
    /// sub-second-precision-dependent.
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    static func url(_ s: String) -> URL {
        // Force-unwrapping is allowed in tests only; a bad literal here is a test bug.
        URL(string: s)!
    }

    /// Six 1 000-byte segments at 100 / 78 / 64 / 57 / 41 / 22 %, laid end to end over a
    /// 6 000-byte file. Received bytes sum to 3 620 — 60 % of the file — while the leading
    /// contiguous run stops far short of that.
    static func staggeredSegments() -> [Download.Segment] {
        let width: Int64 = 1_000
        let percentages: [Double] = [1.00, 0.78, 0.64, 0.57, 0.41, 0.22]
        return percentages.enumerated().map { i, pct in
            let lower = Int64(i) * width
            return Download.Segment(
                id: i,
                range: lower...(lower + width - 1),
                receivedBytes: Int64((Double(width) * pct).rounded())
            )
        }
    }

    static func sample(
        status: Download.Status = .downloading,
        totalBytes: Int64? = 6_000,
        receivedBytes: Int64 = 0,
        segments: [Download.Segment] = [],
        speedSamples: [Double] = []
    ) -> Download {
        Download(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            url: url("https://cdn.example.com/builds/ubuntu-26.04.iso"),
            filename: "ubuntu-26.04.iso",
            saveDirectory: "/Downloads",
            kind: .https,
            status: status,
            totalBytes: totalBytes,
            receivedBytes: receivedBytes,
            segments: segments,
            speedSamples: speedSamples,
            addedAt: epoch
        )
    }

    // MARK: - Fractions and ETA

    @Test("fractionComplete is 0, not NaN, when the server reported no length")
    func fractionWithUnknownLength() {
        let d = Self.sample(totalBytes: nil, receivedBytes: 4_096)
        #expect(d.fractionComplete == 0)
        #expect(!d.fractionComplete.isNaN)
        #expect(d.fractionComplete.isFinite)
    }

    @Test("fractionComplete is 0, not NaN, when the length is zero")
    func fractionWithZeroLength() {
        let d = Self.sample(totalBytes: 0, receivedBytes: 0)
        #expect(d.fractionComplete == 0)
        #expect(d.fractionComplete.isFinite)
    }

    @Test("fractionComplete is clamped to 0…1 even if the server undercounted")
    func fractionIsClamped() {
        let d = Self.sample(totalBytes: 1_000, receivedBytes: 4_000)
        #expect(d.fractionComplete == 1)
    }

    @Test("eta is nil, never inf, when there is no speed yet")
    func etaWithZeroSpeed() {
        let d = Self.sample(totalBytes: 6_000, receivedBytes: 1_000)
        #expect(d.currentSpeed == 0)
        #expect(d.eta == nil)
        // The bug this guards: remaining / 0 == +inf, which renders as the literal "inf".
        if let eta = d.eta { #expect(eta.isFinite) }
    }

    @Test("eta is nil when the total size is unknown, even at full speed")
    func etaWithUnknownSize() {
        var d = Self.sample(totalBytes: nil, receivedBytes: 1_000)
        d.recordSpeedSample(1_000)
        #expect(d.currentSpeed == 1_000)
        #expect(d.eta == nil)
    }

    @Test("eta divides remaining bytes by the smoothed speed")
    func etaValue() {
        var d = Self.sample(totalBytes: 6_000, receivedBytes: 1_000)
        d.recordSpeedSample(100)
        d.recordSpeedSample(100)
        d.recordSpeedSample(100)
        #expect(d.remainingBytes == 5_000)
        #expect(d.eta == 50)
    }

    @Test("remainingBytes never goes negative and is 0 for an unknown length")
    func remainingBytesIsSafe() {
        #expect(Self.sample(totalBytes: 1_000, receivedBytes: 4_000).remainingBytes == 0)
        #expect(Self.sample(totalBytes: nil, receivedBytes: 4_000).remainingBytes == 0)
        #expect(Self.sample(totalBytes: 6_000, receivedBytes: 1_500).remainingBytes == 4_500)
    }

    @Test("currentSpeed is the mean of the last three samples, and 0 when there are none")
    func currentSpeedWindow() {
        var d = Self.sample()
        #expect(d.currentSpeed == 0)
        d.recordSpeedSample(1_000)
        d.recordSpeedSample(10)
        d.recordSpeedSample(20)
        d.recordSpeedSample(30)
        #expect(d.currentSpeed == 20)   // (10 + 20 + 30) / 3 — the 1 000 spike has aged out
    }

    // MARK: - Segments

    @Test("A segment range is inclusive on both ends: 0...99 is exactly 100 bytes")
    func segmentLengthIsInclusive() {
        let s = Download.Segment(id: 0, range: 0...99)
        #expect(s.totalBytes == 100)
        // Matches how HTTP counts: `Range: bytes=0-99` requests 100 bytes.
        #expect(s.fraction == 0)
        #expect(!s.isComplete)
        #expect(s.cursor == 0)
    }

    @Test("A segment's cursor is the next byte it needs, and nil once complete")
    func segmentCursor() {
        let partial = Download.Segment(id: 1, range: 1_000...1_999, receivedBytes: 780)
        #expect(partial.cursor == 1_780)
        #expect(partial.fraction == 0.78)
        #expect(!partial.isComplete)

        let done = Download.Segment(id: 1, range: 1_000...1_999, receivedBytes: 1_000)
        #expect(done.cursor == nil)
        #expect(done.isComplete)
        #expect(done.fraction == 1)
    }

    @Test("Segment fraction is NaN-safe and clamped")
    func segmentFractionIsSafe() {
        let over = Download.Segment(id: 0, range: 0...99, receivedBytes: 400)
        #expect(over.fraction == 1)
        #expect(over.fraction.isFinite)
    }

    // MARK: - Contiguous prefix

    @Test("contiguousPrefix stops at the first hole — it is not the sum of received bytes")
    func contiguousPrefixWithStaggeredSegments() {
        let segments = Self.staggeredSegments()
        let sum = segments.reduce(Int64(0)) { $0 + $1.receivedBytes }
        let d = Self.sample(totalBytes: 6_000, receivedBytes: sum, segments: segments)

        #expect(sum == 3_620)                       // ~60 % of the file is downloaded…
        #expect(d.contiguousPrefix < sum)           // …but nowhere near that much is usable.

        // Segment 0 (0...999) is complete, so the run reaches at least byte 1 000. Segment 1
        // streams forward from 1 000 and is 78 % done, so its 780 received bytes are still
        // contiguous with the run; segment 2 is separated from byte 0 by segment 1's hole.
        #expect(d.contiguousPrefix >= segments[0].totalBytes)
        #expect(d.contiguousPrefix == 1_780)
    }

    @Test("contiguousPrefix reaches the end of the file once every segment is complete")
    func contiguousPrefixWhenAllComplete() {
        let width: Int64 = 1_000
        let segments = (0..<6).map { i -> Download.Segment in
            let lower = Int64(i) * width
            return Download.Segment(id: i, range: lower...(lower + width - 1), receivedBytes: width)
        }
        let d = Self.sample(totalBytes: 6_000, receivedBytes: 6_000, segments: segments)
        #expect(d.contiguousPrefix == 6_000)
    }

    @Test("contiguousPrefix tracks a single sequential segment — T10's playable watermark")
    func contiguousPrefixSequential() {
        let d = Self.sample(
            totalBytes: 6_000,
            receivedBytes: 1_234,
            segments: [Download.Segment(id: 0, range: 0...5_999, receivedBytes: 1_234, isActive: true)]
        )
        #expect(d.contiguousPrefix == 1_234)
    }

    @Test("contiguousPrefix is 0 when the leading bytes are missing entirely")
    func contiguousPrefixWithLeadingHole() {
        let d = Self.sample(
            totalBytes: 6_000,
            receivedBytes: 500,
            segments: [Download.Segment(id: 1, range: 3_000...5_999, receivedBytes: 500)]
        )
        #expect(d.contiguousPrefix == 0)
    }

    @Test("contiguousPrefix falls back to receivedBytes when no segments are recorded")
    func contiguousPrefixWithoutSegments() {
        let d = Self.sample(totalBytes: 6_000, receivedBytes: 900, segments: [])
        #expect(d.contiguousPrefix == 900)
    }

    // MARK: - Speed ring buffer

    @Test("recordSpeedSample caps the buffer at 60 and keeps the newest samples")
    func speedBufferIsBounded() {
        var d = Self.sample()
        for i in 0..<500 { d.recordSpeedSample(Double(i)) }
        #expect(d.speedSamples.count == 60)
        #expect(d.speedSamples.first == 440)
        #expect(d.speedSamples.last == 499)
    }

    @Test("recordSpeedSample rejects NaN and infinity outright")
    func speedBufferRejectsNonFinite() {
        var d = Self.sample()
        d.recordSpeedSample(.nan)
        d.recordSpeedSample(.infinity)
        d.recordSpeedSample(-.infinity)
        #expect(d.speedSamples.isEmpty)

        d.recordSpeedSample(42)
        d.recordSpeedSample(.nan)
        #expect(d.speedSamples == [42])
        #expect(d.currentSpeed == 42)
        let allFinite = d.speedSamples.allSatisfy(\.isFinite)
        #expect(allFinite)
    }

    @Test("The initializer also filters and bounds an injected sample array")
    func initializerBoundsSamples() {
        let d = Self.sample(speedSamples: Array(repeating: Double(5), count: 200) + [.nan])
        #expect(d.speedSamples.count == 60)
        let allFinite = d.speedSamples.allSatisfy(\.isFinite)
        #expect(allFinite)
    }

    // MARK: - Coding

    @Test("A Download survives a JSON round trip unchanged")
    func jsonRoundTrip() throws {
        var original = Self.sample(
            status: .paused,
            totalBytes: 1_000_000,
            receivedBytes: 250_000,
            segments: Self.staggeredSegments(),
            speedSamples: [10, 20, 30]
        )
        original.completedAt = Date(timeIntervalSince1970: 1_700_000_500)
        original.checksumVerified = true
        original.isSequential = true
        original.supportsResume = true
        original.validator = "\"9a3f-5e2\""
        original.errorMessage = nil

        let data = try Download.makeEncoder().encode(original)
        let decoded = try Download.makeDecoder().decode(Download.self, from: data)
        #expect(decoded == original)
        #expect(decoded.segments == original.segments)
        #expect(decoded.hashValue == original.hashValue)
    }

    @Test("An array of Downloads round-trips — the shape the store persists")
    func jsonArrayRoundTrip() throws {
        let items = [Self.sample(), Self.sample(status: .completed, totalBytes: 10, receivedBytes: 10)]
        let data = try Download.makeEncoder().encode(items)
        let decoded = try Download.makeDecoder().decode([Download].self, from: data)
        #expect(decoded == items)
    }

    @Test("Dates encode as Unix seconds, not Foundation's 2001 epoch")
    func datesUseUnixSeconds() throws {
        let d = Self.sample()   // addedAt == 1_700_000_000
        let json = String(decoding: try Download.makeEncoder().encode(d), as: UTF8.self)
        #expect(json.contains("1700000000"))
        // Foundation's default (.deferredToDate) would have written 721692800 — the same
        // instant counted from 2001. A silent 31-year offset the moment anything else reads it.
        #expect(!json.contains("721692800"))
    }

    @Test("Encoded keys are sorted, so a persisted file is byte-stable across runs")
    func encodingIsDeterministic() throws {
        let d = Self.sample()
        let a = try Download.makeEncoder().encode(d)
        let b = try Download.makeEncoder().encode(d)
        #expect(a == b)
    }

    // MARK: - Kind and Status

    @Test("Kind.infer reads the scheme, with playlist extensions winning")
    func kindInference() {
        #expect(Download.Kind.infer(from: Self.url("http://example.com/a.bin")) == .http)
        #expect(Download.Kind.infer(from: Self.url("https://example.com/a.bin")) == .https)
        #expect(Download.Kind.infer(from: Self.url("ftp://example.com/a.bin")) == .ftp)
        #expect(Download.Kind.infer(from: Self.url("sftp://example.com/a.bin")) == .sftp)
        // An HLS manifest arrives over https but behaves nothing like a file download.
        #expect(Download.Kind.infer(from: Self.url("https://example.com/stream.m3u8")) == .hls)
    }

    @Test("There is no torrent kind — PRD §8.1 excludes BitTorrent")
    func noTorrentKind() {
        #expect(Download.Kind.allCases.count == 5)
        let mentionsTorrent = Download.Kind.allCases.contains { $0.rawValue.contains("torrent") }
        #expect(!mentionsTorrent)
        let everyKindHasASymbol = Download.Kind.allCases.allSatisfy { !$0.systemImage.isEmpty }
        #expect(everyKindHasASymbol)
    }

    @Test("kindToken is the lowercase raw value the widgets print")
    func kindTokens() {
        #expect(Download.Kind.sftp.token == "sftp")
        #expect(Download.Kind.allCases.map(\.token) == ["http", "https", "ftp", "sftp", "hls"])
    }

    @Test("Status partitions cleanly into active, terminal, and neither")
    func statusFlags() {
        #expect(Download.Status.downloading.isActive)
        #expect(Download.Status.probing.isActive)
        #expect(Download.Status.verifying.isActive)
        #expect(!Download.Status.paused.isActive)
        #expect(!Download.Status.queued.isActive)
        #expect(!Download.Status.waitingForWiFi.isActive)

        #expect(Download.Status.completed.isTerminal)
        #expect(Download.Status.failed.isTerminal)
        #expect(!Download.Status.downloading.isTerminal)

        // Nothing is both.
        let bothAtOnce = Download.Status.allCases.contains { $0.isActive && $0.isTerminal }
        #expect(!bothAtOnce)
        let everyStatusIsNamed = Download.Status.allCases.allSatisfy { !$0.displayName.isEmpty }
        #expect(everyStatusIsNamed)
    }

    @Test("waitingForWiFi reads as a Wi-Fi wait, hyphenated so it cannot wrap mid-word")
    func waitingForWiFiDisplayName() {
        let name = Download.Status.waitingForWiFi.displayName
        #expect(name.hasPrefix("Waiting for Wi"))
        #expect(name.hasSuffix("Fi"))
        #expect(name.contains("\u{2011}"))   // non-breaking hyphen
    }

    @Test("sourceHost is the URL host, and empty rather than nil for a hostless URL")
    func sourceHost() {
        #expect(Self.sample().sourceHost == "cdn.example.com")
        let fileBased = Download(
            url: Self.url("file:///var/tmp/a.bin"),
            filename: "a.bin",
            saveDirectory: "/Downloads",
            kind: .https
        )
        #expect(fileBased.sourceHost.isEmpty)
    }
}
