import Foundation
import Testing
@testable import Goel

/// The player's arithmetic, without a simulator.
///
/// Everything that decides what the user sees on the play-while-downloading screen is a pure
/// function over value types — the buffered edge, the seek clamp, the buffer lead in minutes, and
/// the resource loader's range decisions. All four are here. What is *not* here is AVFoundation:
/// whether `AVPlayer` decodes a frame is a simulator question, and the file that answers it is
/// `Scripts/ios/fixtures/sample-video.mp4`.
///
/// The recurring theme is the same one that governs ``Fmt``: a division whose denominator can be
/// zero is a `NaN` or an `inf` on its way to a `Text` view. Every one of them is guarded, and
/// every guard is asserted here.
@Suite("Player buffer maths")
struct PlayerBufferTests {

    // MARK: - Buffered fraction

    @Test("The buffered edge is the contiguous prefix over the total, not the received bytes")
    func bufferedEdgeComesFromTheContiguousPrefix() {
        // 23 % — the mockup's number.
        #expect(ScrubMath.bufferedFraction(contiguousPrefix: 230, totalBytes: 1000) == 0.23)
        #expect(ScrubMath.bufferedFraction(contiguousPrefix: 0, totalBytes: 1000) == 0)
        #expect(ScrubMath.bufferedFraction(contiguousPrefix: 1000, totalBytes: 1000) == 1)
    }

    @Test("A download with holes exposes only its leading run as buffered")
    func holesDoNotCountAsBuffered() {
        // Six segments over 600 bytes. The first is complete, the second is half done, the rest
        // have bytes but are separated from byte 0 by that hole — 350 received, 150 playable.
        let segments: [Download.Segment] = [
            .init(id: 0, range: 0...99, receivedBytes: 100),
            .init(id: 1, range: 100...199, receivedBytes: 50),
            .init(id: 2, range: 200...299, receivedBytes: 100),
            .init(id: 3, range: 300...399, receivedBytes: 100),
            .init(id: 4, range: 400...499, receivedBytes: 0),
            .init(id: 5, range: 500...599, receivedBytes: 0),
        ]
        let download = Download(
            url: URL(filePath: "/dev/null"),
            filename: "f.mp4",
            saveDirectory: "Goel°",
            kind: .https,
            totalBytes: 600,
            receivedBytes: 350,
            segments: segments
        )
        #expect(download.contiguousPrefix == 150)
        let fraction = ScrubMath.bufferedFraction(
            contiguousPrefix: download.contiguousPrefix,
            totalBytes: download.totalBytes
        )
        #expect(fraction == 0.25)
        // The naive number a lesser implementation would draw.
        #expect(fraction != download.fractionComplete)
    }

    @Test("The buffered edge is NaN-safe and clamps to 0…1")
    func bufferedEdgeIsSafe() {
        #expect(ScrubMath.bufferedFraction(contiguousPrefix: 100, totalBytes: nil) == 0)
        #expect(ScrubMath.bufferedFraction(contiguousPrefix: 100, totalBytes: 0) == 0)
        #expect(ScrubMath.bufferedFraction(contiguousPrefix: 100, totalBytes: -5) == 0)
        // A prefix past the total (a re-probed shorter file) must not exceed the track.
        #expect(ScrubMath.bufferedFraction(contiguousPrefix: 5000, totalBytes: 1000) == 1)
        #expect(ScrubMath.bufferedFraction(contiguousPrefix: -100, totalBytes: 1000) == 0)
        for value in [
            ScrubMath.bufferedFraction(contiguousPrefix: 100, totalBytes: nil),
            ScrubMath.bufferedFraction(contiguousPrefix: .max, totalBytes: 1),
        ] {
            #expect(value.isFinite)
        }
    }

    // MARK: - Seek clamping

    @Test("A seek inside the buffer is honoured and does not report a clamp")
    func seekInsideTheBufferIsHonoured() {
        let result = ScrubMath.resolveSeek(fraction: 0.10, bufferedEdge: 0.23)
        #expect(result.fraction == 0.10)
        #expect(result.didClamp == false)
    }

    @Test("A seek past the buffered edge clamps to the edge and says so")
    func seekPastTheEdgeClamps() {
        let result = ScrubMath.resolveSeek(fraction: 0.80, bufferedEdge: 0.23)
        #expect(result.fraction == 0.23)
        #expect(result.didClamp)
    }

    @Test("A seek exactly on the edge is not a clamp")
    func seekOnTheEdgeIsNotAClamp() {
        let result = ScrubMath.resolveSeek(fraction: 0.23, bufferedEdge: 0.23)
        #expect(result.fraction == 0.23)
        #expect(result.didClamp == false)
    }

    @Test("A drag that runs off either end of the track still resolves to a real position")
    func seekOffTheTrackResolves() {
        let low = ScrubMath.resolveSeek(fraction: -0.4, bufferedEdge: 0.23)
        #expect(low.fraction == 0)
        #expect(low.didClamp == false)

        let high = ScrubMath.resolveSeek(fraction: 1.9, bufferedEdge: 0.23)
        #expect(high.fraction == 0.23)
        #expect(high.didClamp)

        // Fully downloaded: dragging off the right-hand end is not a refusal.
        let complete = ScrubMath.resolveSeek(fraction: 1.9, bufferedEdge: 1)
        #expect(complete.fraction == 1)
        #expect(complete.didClamp == false)

        let broken = ScrubMath.resolveSeek(fraction: .nan, bufferedEdge: .nan)
        #expect(broken.fraction == 0)
        #expect(broken.didClamp == false)
    }

    // MARK: - Buffer lead

    @Test("The buffer lead is expressed in minutes of media at the file's own bitrate")
    func bufferLeadUsesTheMediaBitrate() throws {
        // 3 600 s of media in 3 600 000 bytes — 1 000 bytes per second of video. The playhead is
        // 100 000 bytes in (100 s), the download has reached 2 080 000 (2 080 s): 1 980 s = 33 min.
        let lead = try #require(ScrubMath.bufferLeadSeconds(
            contiguousPrefix: 2_080_000,
            playheadBytes: 100_000,
            totalBytes: 3_600_000,
            duration: 3600
        ))
        #expect(lead == 1980)
        #expect(ScrubMath.leadLabel(lead) == "+33 min")
    }

    @Test("A playhead ahead of the write head reports no lead rather than a negative one")
    func bufferLeadNeverGoesNegative() throws {
        let lead = try #require(ScrubMath.bufferLeadSeconds(
            contiguousPrefix: 1000,
            playheadBytes: 9000,
            totalBytes: 3_600_000,
            duration: 3600
        ))
        #expect(lead == 0)
        #expect(ScrubMath.leadLabel(lead) == "+0 s")
    }

    @Test("An unknown size or duration produces nil, never inf")
    func bufferLeadIsNilRatherThanInfinite() {
        #expect(ScrubMath.bufferLeadSeconds(
            contiguousPrefix: 1000, playheadBytes: 0, totalBytes: nil, duration: 3600
        ) == nil)
        #expect(ScrubMath.bufferLeadSeconds(
            contiguousPrefix: 1000, playheadBytes: 0, totalBytes: 0, duration: 3600
        ) == nil)
        // Duration is 0 for the first moments of every asset — this is the common case, not an
        // edge case, and `bytes / 0` is exactly the `inf` that renders as "inf" in a Text.
        #expect(ScrubMath.bufferLeadSeconds(
            contiguousPrefix: 1000, playheadBytes: 0, totalBytes: 3_600_000, duration: 0
        ) == nil)
        #expect(ScrubMath.bufferLeadSeconds(
            contiguousPrefix: 1000, playheadBytes: 0, totalBytes: 3_600_000, duration: .infinity
        ) == nil)
        #expect(ScrubMath.bufferLeadSeconds(
            contiguousPrefix: 1000, playheadBytes: 0, totalBytes: 3_600_000, duration: .nan
        ) == nil)
        #expect(ScrubMath.leadLabel(nil) == Fmt.placeholder)
    }

    @Test("The lead label reads in the units a person can act on")
    func leadLabelUnits() {
        #expect(ScrubMath.leadLabel(45) == "+45 s")
        #expect(ScrubMath.leadLabel(60) == "+1 min")
        #expect(ScrubMath.leadLabel(1980) == "+33 min")
        #expect(ScrubMath.leadLabel(4320) == "+1 h 12 min")
        #expect(ScrubMath.leadLabel(-5) == Fmt.placeholder)
        #expect(ScrubMath.leadLabel(.infinity) == Fmt.placeholder)
    }

    @Test("The playhead byte offset is guarded on both divisions")
    func playheadBytesIsSafe() {
        #expect(ScrubMath.playheadBytes(position: 100, duration: 3600, totalBytes: 3_600_000) == 100_000)
        #expect(ScrubMath.playheadBytes(position: 100, duration: 0, totalBytes: 3_600_000) == 0)
        #expect(ScrubMath.playheadBytes(position: 100, duration: 3600, totalBytes: nil) == 0)
        #expect(ScrubMath.playheadBytes(position: .nan, duration: 3600, totalBytes: 3_600_000) == 0)
        // Past the end of the media clamps to the last byte rather than running off the file.
        #expect(ScrubMath.playheadBytes(position: 9999, duration: 3600, totalBytes: 3_600_000) == 3_600_000)
    }

    // MARK: - Resource loader range arithmetic

    @Test("A request wholly inside the written prefix is served now")
    func requestInsideThePrefixIsReady() {
        let window = PartialFileWindow(writeHead: 1000, totalBytes: 5000)
        #expect(window.fulfilment(offset: 0, length: 500) == .ready(offset: 0, length: 500))
        #expect(window.fulfilment(offset: 500, length: 500) == .ready(offset: 500, length: 500))
    }

    @Test("A request straddling the write head is served as far as the bytes go")
    func requestStraddlingTheWriteHeadIsPartial() {
        let window = PartialFileWindow(writeHead: 1000, totalBytes: 5000)
        #expect(window.fulfilment(offset: 900, length: 400) == .partial(offset: 900, length: 100))
        #expect(window.fulfilment(offset: 0, length: 4000) == .partial(offset: 0, length: 1000))
    }

    @Test("A request entirely past the write head pends — it must not fail")
    func requestPastTheWriteHeadPends() {
        let window = PartialFileWindow(writeHead: 1000, totalBytes: 5000)
        // Failing these is what makes AVPlayer treat the write head as end-of-stream.
        #expect(window.fulfilment(offset: 1000, length: 100) == .pending)
        #expect(window.fulfilment(offset: 4000, length: 100) == .pending)
    }

    @Test("A request past the end of a file of known length is exhausted, not pending")
    func requestPastTheEndIsExhausted() {
        let window = PartialFileWindow(writeHead: 5000, totalBytes: 5000)
        #expect(window.fulfilment(offset: 5000, length: 100) == .exhausted)
        #expect(window.fulfilment(offset: 6000, length: 100) == .exhausted)
        #expect(window.fulfilment(offset: 0, length: 0) == .exhausted)
        // The tail of the file is clamped to the real length rather than over-read.
        #expect(window.fulfilment(offset: 4900, length: 500) == .ready(offset: 4900, length: 100))
    }

    @Test("Widening the window releases a range that was pending a moment ago")
    func advancingTheWriteHeadReleasesAPendingRange() {
        var window = PartialFileWindow(writeHead: 1000, totalBytes: 5000)
        #expect(window.fulfilment(offset: 2000, length: 100) == .pending)
        window.writeHead = 2500
        #expect(window.fulfilment(offset: 2000, length: 100) == .ready(offset: 2000, length: 100))
    }

    @Test("An unknown total length still serves what is on disk")
    func unknownTotalStillServes() {
        let window = PartialFileWindow(writeHead: 1000, totalBytes: nil)
        #expect(window.fulfilment(offset: 0, length: 400) == .ready(offset: 0, length: 400))
        #expect(window.fulfilment(offset: 900, length: 400) == .partial(offset: 900, length: 100))
        #expect(window.fulfilment(offset: 1000, length: 400) == .pending)
    }

    @Test("Negative offsets and lengths cannot produce a read outside the file")
    func degenerateRangesAreRejected() {
        let window = PartialFileWindow(writeHead: 1000, totalBytes: 5000)
        #expect(window.fulfilment(offset: -100, length: 200) == .ready(offset: 0, length: 200))
        #expect(window.fulfilment(offset: 100, length: -5) == .exhausted)
    }

    // MARK: - Container layout

    @Test("A faststart file — moov ahead of mdat — is detected as playable from a prefix")
    func fastStartIsDetected() {
        let data = Self.mp4Header(order: ["ftyp", "moov", "mdat"])
        #expect(MediaContainer.inspect(data) == .fastStart)
    }

    @Test("A file with its index at the end is detected, so the UI can say why it will not play")
    func moovAtTheEndIsDetected() {
        let data = Self.mp4Header(order: ["ftyp", "free", "mdat"])
        #expect(MediaContainer.inspect(data) == .moovAtEnd)
    }

    @Test("Too few bytes, or a container this walk does not understand, stays undetermined")
    func undeterminedRatherThanGuessing() {
        #expect(MediaContainer.inspect(Data()) == .undetermined)
        #expect(MediaContainer.inspect(Data([0, 0, 0, 1])) == .undetermined)
        // Matroska's EBML header — not an ISO base-media file. Let AVFoundation decide.
        #expect(MediaContainer.inspect(Data([0x1A, 0x45, 0xDF, 0xA3, 0x01, 0x00, 0x00, 0x00])) == .undetermined)
        // A box whose declared size is smaller than its own header is corrupt, not a verdict.
        #expect(MediaContainer.inspect(Data([0, 0, 0, 2]) + Data("ftyp".utf8)) == .undetermined)
    }

    @Test("The real fixture is faststart, which is why it can be played at 23 %")
    func theShippedFixtureIsFastStart() throws {
        // `moov` at offset 36, `mdat` at 22458 — verified when the fixture was generated. If this
        // ever inverts, the play-while-downloading gate stops being a test of the player.
        let fixture = URL(filePath: #filePath)
            .deletingLastPathComponent()          // apps/ios/GoelTests
            .deletingLastPathComponent()          // apps/ios
            .deletingLastPathComponent()          // apps
            .deletingLastPathComponent()          // repository root
            .appending(path: "Scripts/ios/fixtures/sample-video.mp4")

        try #require(
            FileManager.default.fileExists(atPath: fixture.path),
            "Scripts/ios/fixtures/sample-video.mp4 is missing from the working tree"
        )
        let handle = try FileHandle(forReadingFrom: fixture)
        defer { try? handle.close() }
        let head = try #require(try handle.read(upToCount: MediaContainer.probeBytes))
        #expect(MediaContainer.inspect(head) == .fastStart)
    }

    // MARK: - Fixtures

    /// A synthetic top-level box list. Only the sizes and the four-character types matter to the
    /// walk, so the payloads are zeros.
    private static func mp4Header(order: [String]) -> Data {
        var data = Data()
        for type in order {
            let payload = 24
            let size = UInt32(8 + payload)
            data.append(contentsOf: [
                UInt8((size >> 24) & 0xFF),
                UInt8((size >> 16) & 0xFF),
                UInt8((size >> 8) & 0xFF),
                UInt8(size & 0xFF),
            ])
            data.append(contentsOf: Array(type.utf8))
            data.append(Data(repeating: 0, count: payload))
        }
        return data
    }
}
