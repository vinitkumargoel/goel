import CryptoKit
import Foundation
import SwiftUI
import Testing
@testable import Goel

/// T06's gate.
///
/// The simulator does not truly suspend apps, so watching a download survive a Home-button press
/// on a simulator proves close to nothing. The PRD's real acceptance test — 4 GB, backgrounded at
/// 10 %, locked an hour, airplane mode toggled once — needs a physical device and an hour. What
/// *can* be proven on every build is that the arithmetic the handoff turns on is right, and that
/// arithmetic is entirely in ``HandoffState`` and ``Download/contiguousPrefix``.
///
/// The one bug this file exists to prevent: resuming a background task from `receivedBytes`
/// instead of the contiguous prefix. That writes the remainder of the file too early, produces a
/// file of exactly the right length, and is invisible until someone opens it.
@Suite("Handoff state machine")
struct HandoffTests {

    // MARK: - Fixtures

    static func url(_ string: String) -> URL {
        // Force unwrap is allowed in tests only; a bad literal here is a test bug.
        URL(string: string)!
    }

    /// Six 1 000-byte segments laid end to end over a 6 000-byte file, at 100/78/64/57/41/22 %.
    ///
    /// The numbers are the ones in `visual.html`. Their sum is 3 620 bytes — 60 % of the file —
    /// and the contiguous prefix is 1 780: segment 0 is complete, so segment 1's 780 bytes
    /// continue it, and segment 1 is incomplete, so the run stops there. Every other segment's
    /// bytes are separated from byte 0 by a hole.
    static func staggeredSegments() -> [Download.Segment] {
        let width: Int64 = 1_000
        let permille: [Int64] = [1_000, 780, 640, 570, 410, 220]
        return permille.enumerated().map { index, value in
            let lower = Int64(index) * width
            return Download.Segment(
                id: index,
                range: lower...(lower + width - 1),
                receivedBytes: width * value / 1_000,
                isActive: value < 1_000
            )
        }
    }

    static func download(
        status: Download.Status = .downloading,
        totalBytes: Int64? = 6_000,
        receivedBytes: Int64 = 3_620,
        segments: [Download.Segment] = HandoffTests.staggeredSegments(),
        supportsResume: Bool = true,
        isSequential: Bool = false,
        validator: String? = "\"abc-123\""
    ) -> Download {
        Download(
            id: UUID(uuid: (0x60, 0xE1, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 0x11)),
            url: url("https://example.com/big.iso"),
            filename: "big.iso",
            saveDirectory: "",
            kind: .https,
            status: status,
            totalBytes: totalBytes,
            receivedBytes: receivedBytes,
            segments: segments,
            isSequential: isSequential,
            supportsResume: supportsResume,
            validator: validator
        )
    }

    // MARK: - The contiguous prefix

    @Test("A gapped segment set reports the prefix, never the sum")
    func gappedPrefixIsNotTheSum() {
        let subject = Self.download()
        let sum = subject.segments.reduce(Int64(0)) { $0 + $1.receivedBytes }

        #expect(sum == 3_620)
        // Segment 0 complete (1 000) + segment 1's contiguous 780. Not 1 000, and not 3 620.
        #expect(subject.contiguousPrefix == 1_780)
        #expect(subject.contiguousPrefix < sum)
        #expect(subject.contiguousPrefix < subject.receivedBytes)
    }

    @Test("The prefix always reaches past the last fully-complete leading segment")
    func prefixCoversCompleteLeadingSegments() {
        let subject = Self.download()
        let leadingComplete = subject.segments
            .sorted { $0.range.lowerBound < $1.range.lowerBound }
            .prefix { $0.isComplete }
        let expectedFloor = leadingComplete.last.map { $0.range.upperBound + 1 } ?? 0

        #expect(expectedFloor == 1_000)
        #expect(subject.contiguousPrefix >= expectedFloor)
    }

    @Test("Every segment complete means the prefix is the whole file")
    func completePrefixIsTheTotal() {
        let segments = (0..<6).map { index -> Download.Segment in
            let lower = Int64(index) * 1_000
            return Download.Segment(id: index, range: lower...(lower + 999), receivedBytes: 1_000)
        }
        let subject = Self.download(receivedBytes: 6_000, segments: segments)

        #expect(subject.contiguousPrefix == 6_000)
        #expect(subject.contiguousPrefix == subject.totalBytes)
        #expect(HandoffState.rangeForResume(subject) == nil)
    }

    @Test("With no segments the prefix is receivedBytes — a single stream is contiguous by definition")
    func singleStreamPrefix() {
        let subject = Self.download(receivedBytes: 2_500, segments: [])
        #expect(subject.contiguousPrefix == 2_500)
        #expect(HandoffState.rangeForResume(subject) == 2_500...5_999)
    }

    @Test("A single sequential segment at 50 % is playable to the halfway mark, not to zero")
    func sequentialSingleSegmentPrefix() {
        // T10 reads this value to decide how much of the file is safe to hand to AVPlayer.
        // "The end of segment 0" would answer 0 here and break play-while-downloading outright.
        let segment = Download.Segment(id: 0, range: 0...5_999, receivedBytes: 3_000, isActive: true)
        let subject = Self.download(receivedBytes: 3_000, segments: [segment], isSequential: true)

        #expect(subject.contiguousPrefix == 3_000)
        #expect(HandoffState.rangeForResume(subject) == 3_000...5_999)
    }

    @Test("A hole in the very first segment stops the prefix inside it")
    func holeInsideFirstSegment() {
        let segments = [
            Download.Segment(id: 0, range: 0...999, receivedBytes: 400, isActive: true),
            Download.Segment(id: 1, range: 1_000...1_999, receivedBytes: 1_000),
        ]
        let subject = Self.download(totalBytes: 2_000, receivedBytes: 1_400, segments: segments)
        // Segment 1 is complete but unreachable: bytes 400...999 are missing.
        #expect(subject.contiguousPrefix == 400)
        #expect(subject.contiguousPrefix < subject.receivedBytes)
    }

    // MARK: - Range headers

    @Test("bytes=0-99 is one hundred bytes, inclusive on both ends")
    func rangeHeaderIsInclusive() {
        let range: ClosedRange<Int64> = 0...99
        #expect(HandoffState.rangeHeaderValue(range) == "bytes=0-99")
        #expect(range.upperBound - range.lowerBound + 1 == 100)
    }

    @Test("A resume range starts at the prefix and ends at the last byte of the file")
    func resumeRangeIsAnchoredOnThePrefix() throws {
        let subject = Self.download()
        let range = try #require(HandoffState.rangeForResume(subject))

        #expect(range == 1_780...5_999)
        #expect(range.lowerBound == subject.contiguousPrefix)
        // The bug this whole file exists to prevent.
        #expect(range.lowerBound != subject.receivedBytes)
        #expect(HandoffState.rangeHeaderValue(range) == "bytes=1780-5999")
    }

    @Test("No length means no resume range — a Range header needs an end")
    func resumeRangeNeedsALength() {
        #expect(HandoffState.rangeForResume(Self.download(totalBytes: nil)) == nil)
    }

    // MARK: - Adoption

    @Test("A matching validator may be adopted; a changed one may not")
    func adoptionRequiresAMatchingValidator() {
        let subject = Self.download(validator: "\"v1\"")

        #expect(HandoffState.canAdoptBackgroundResult(subject, validator: "\"v1\""))
        #expect(!HandoffState.canAdoptBackgroundResult(subject, validator: "\"v2\""))
    }

    @Test("A validator that has disappeared may not be adopted")
    func adoptionRefusesAMissingValidator() {
        // The server used to send an ETag and no longer does. It may be the same file. There is
        // no way to tell, and an unprovable splice is the corruption case.
        #expect(!HandoffState.canAdoptBackgroundResult(Self.download(validator: "\"v1\""), validator: nil))
    }

    @Test("With no validator on either side, adoption is only safe from zero")
    func adoptionWithNoValidatorAtAll() {
        let withBytes = Self.download(validator: nil)
        #expect(!HandoffState.canAdoptBackgroundResult(withBytes, validator: nil))

        let fresh = Self.download(receivedBytes: 0, segments: [], validator: nil)
        #expect(HandoffState.canAdoptBackgroundResult(fresh, validator: nil))

        // A validator appearing where there was none is equally unprovable.
        #expect(!HandoffState.canAdoptBackgroundResult(withBytes, validator: "\"new\""))
    }

    // MARK: - The background ⇄ foreground cycle

    @Test("background → active → background does not double-count bytes")
    func cycleDoesNotDoubleCount() {
        let start = Self.download()
        #expect(start.contiguousPrefix == 1_780)

        // Background task runs and makes bytes 0..<4_000 contiguous.
        let afterFirstBackground = HandoffState.adopting(start, contiguousBytes: 4_000)
        // 4_410, not 4_000: segment 4 covers 4_000…4_999 and its own forward run already holds
        // 410 bytes starting at exactly 4_000, so those bytes continue the prefix rather than
        // sitting behind a hole. Adoption must not throw them away.
        #expect(afterFirstBackground.contiguousPrefix == 4_410)
        #expect(afterFirstBackground.contiguousPrefix >= 4_000)
        #expect(afterFirstBackground.receivedBytes <= 6_000)

        // The coordinator replays the same completion (an app relaunch re-reads its manifest).
        // Absolute offsets rather than deltas are what makes this a no-op.
        let replayed = HandoffState.adopting(afterFirstBackground, contiguousBytes: 4_000)
        #expect(replayed.receivedBytes == afterFirstBackground.receivedBytes)
        #expect(replayed.contiguousPrefix == afterFirstBackground.contiguousPrefix)
        #expect(replayed.segments == afterFirstBackground.segments)

        // Foreground re-segments, then we background again — from the prefix, which has moved on.
        let secondRange = HandoffState.rangeForResume(replayed)
        #expect(secondRange == 4_410...5_999)
        #expect(secondRange?.lowerBound == replayed.contiguousPrefix)

        let afterSecondBackground = HandoffState.adopting(replayed, contiguousBytes: 6_000)
        #expect(afterSecondBackground.receivedBytes == 6_000)
        #expect(afterSecondBackground.contiguousPrefix == 6_000)
        #expect(HandoffState.rangeForResume(afterSecondBackground) == nil)
    }

    @Test("Adoption keeps foreground bytes that lie beyond the background task's reach")
    func adoptionKeepsLaterBytes() {
        let start = Self.download()
        // Segment 5 covers 5_000...5_999 and holds 220 bytes at 5_000...5_219. Those bytes are
        // real and on disk; a background task that only reached 2_000 must not discard them.
        let adopted = HandoffState.adopting(start, contiguousBytes: 2_000)

        // 2_640: the background task reached 2_000, and segment 2's own 640 bytes start there.
        #expect(adopted.contiguousPrefix == 2_640)
        #expect(adopted.receivedBytes > 2_000)
        let tail = adopted.segments.first { $0.range.lowerBound == 5_000 }
        #expect(tail?.receivedBytes == 220)
    }

    @Test("Adoption never reports more bytes than the file has")
    func adoptionClampsToTotal() {
        let adopted = HandoffState.adopting(Self.download(), contiguousBytes: 99_999)
        #expect(adopted.receivedBytes == 6_000)
        #expect(adopted.contiguousPrefix == 6_000)
    }

    // MARK: - Strategy

    @Test("Paused, completed and failed downloads are suspended in every phase")
    func terminalStatesAreSuspended() {
        for status in [Download.Status.paused, .completed, .failed, .waitingForWiFi, .verifying] {
            let subject = Self.download(status: status)
            #expect(HandoffState.strategy(for: .active, download: subject) == .suspended)
            #expect(HandoffState.strategy(for: .background, download: subject) == .suspended)
        }
    }

    @Test("Backgrounded mid-transfer hands over to a single background task")
    func backgroundedMidTransfer() {
        let subject = Self.download()
        #expect(HandoffState.strategy(for: .background, download: subject) == .backgroundSingle)
        #expect(HandoffState.strategy(for: .active, download: subject) == .segmented)
        // `.inactive` is the app switcher and the incoming-call banner. Tearing six connections
        // down for those would cost far more than it saves.
        #expect(HandoffState.strategy(for: .inactive, download: subject) == .segmented)
    }

    @Test("A server without ranges gets no background task — there is nothing to resume from")
    func noRangesMeansNoHandoff() {
        let subject = Self.download(supportsResume: false)
        #expect(HandoffState.strategy(for: .background, download: subject) == .suspended)
        #expect(HandoffState.strategy(for: .active, download: subject) == .segmented)
    }

    @Test("A download whose bytes are all in is suspended, not handed over")
    func finishedBytesAreNotHandedOver() {
        let segments = (0..<6).map { index -> Download.Segment in
            let lower = Int64(index) * 1_000
            return Download.Segment(id: index, range: lower...(lower + 999), receivedBytes: 1_000)
        }
        let subject = Self.download(receivedBytes: 6_000, segments: segments)
        #expect(HandoffState.strategy(for: .background, download: subject) == .suspended)
    }

    // MARK: - Range algebra

    @Test("Merging coalesces overlapping and adjacent ranges")
    func merging() {
        #expect(HandoffState.merged([0...9, 10...19]) == [0...19])
        #expect(HandoffState.merged([0...9, 5...19]) == [0...19])
        #expect(HandoffState.merged([20...29, 0...9]) == [0...9, 20...29])
        #expect(HandoffState.merged([]).isEmpty)
        #expect(HandoffState.merged([0...0]) == [0...0])
    }

    @Test("Gaps are exactly the bytes not yet covered")
    func gaps() {
        #expect(HandoffState.gaps(in: [], total: 100) == [0...99])
        #expect(HandoffState.gaps(in: [0...99], total: 100).isEmpty)
        #expect(HandoffState.gaps(in: [0...49], total: 100) == [50...99])
        #expect(HandoffState.gaps(in: [10...19, 40...49], total: 100) == [0...9, 20...39, 50...99])
    }

    @Test("The prefix of a merged range list is zero unless it starts at byte zero")
    func prefixOfRanges() {
        #expect(HandoffState.contiguousPrefix(of: [0...99]) == 100)
        #expect(HandoffState.contiguousPrefix(of: [1...99]) == 0)
        #expect(HandoffState.contiguousPrefix(of: [0...49, 50...99]) == 100)
        #expect(HandoffState.contiguousPrefix(of: [0...49, 60...99]) == 50)
    }

    // MARK: - Checkpoint safety

    @Test("A checkpoint is only adopted for the same URL and the same validator")
    func checkpointMatching() {
        let subject = TransferCheckpoint(
            url: "https://example.com/big.iso",
            totalBytes: 6_000,
            validator: "\"v1\"",
            supportsResume: true,
            isSequential: false,
            completed: [0...1_779]
        )
        #expect(subject.writtenBytes == 1_780)
        #expect(subject.matches(url: Self.url("https://example.com/big.iso"), validator: "\"v1\""))
        #expect(!subject.matches(url: Self.url("https://example.com/big.iso"), validator: "\"v2\""))
        #expect(!subject.matches(url: Self.url("https://example.com/other.iso"), validator: "\"v1\""))
        #expect(!subject.matches(url: Self.url("https://example.com/big.iso"), validator: nil))

        let unvalidated = TransferCheckpoint(
            url: "https://example.com/big.iso",
            totalBytes: 6_000,
            validator: nil,
            supportsResume: true,
            isSequential: false,
            completed: [0...1_779]
        )
        // No validator means no proof of sameness, so the bytes are dropped rather than spliced.
        #expect(!unvalidated.matches(url: Self.url("https://example.com/big.iso"), validator: nil))
    }

    // MARK: - The splice

    /// The moment the handoff either works or silently ruins the file.
    ///
    /// A background `URLSessionDownloadTask` writes to its own temp file, hands it over once, and
    /// iOS deletes it the instant the delegate method returns. So the coordinator has exactly one
    /// chance to copy those bytes into the real `.part` at the right offset — and "the right
    /// offset" is the offset the task's `Range:` header started at, which is recorded on disk
    /// precisely because the process that receives the completion may be a fresh launch.
    @Test("Splicing a background result at an offset reproduces the file byte for byte")
    func spliceLandsAtTheRightOffset() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "goel-splice-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileStore(root: root)

        // A deterministic 512 KB "file", split the way a handoff splits it: a foreground prefix
        // and a background remainder.
        let total = 512 * 1024
        let offset = 197_531  // deliberately not a block boundary
        var whole = Data(count: total)
        for index in 0..<total {
            whole[index] = UInt8((index &* 31 &+ 7) & 0xFF)
        }
        let expected = SHA256.hash(data: whole).map { String(format: "%02x", $0) }.joined()

        // What the foreground engine already wrote.
        let part = root.appending(path: "movie.mp4.goelpart", directoryHint: .notDirectory)
        let file = try store.openPart(at: part, size: Int64(total))
        try file.write(whole.prefix(offset), at: 0)
        file.synchronize()

        // What the background task hands over: the tail, and only the tail.
        let handover = root.appending(path: "bg-temp", directoryHint: .notDirectory)
        try Data(whole.suffix(from: offset)).write(to: handover)

        let written = try BackgroundCoordinator.splice(
            from: handover,
            into: part,
            at: Int64(offset),
            store: store,
            totalBytes: Int64(total)
        )

        #expect(written == Int64(total - offset))
        #expect(try FileStore.sha256Hex(ofFileAt: part) == expected)
        let size = try FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int64
        #expect(size == Int64(total))
    }

    @Test("A sparse part file is preallocated to its full length before any byte arrives")
    func partFileIsPreallocated() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "goel-sparse-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileStore(root: root)

        let part = root.appending(path: "big.iso.goelpart", directoryHint: .notDirectory)
        let file = try store.openPart(at: part, size: 4_000_000)
        // The last segment writes at its own offset on its very first byte — which is only legal
        // because the file already claims to be that long.
        try file.write(Data([0xAB]), at: 3_999_999)
        file.synchronize()

        let size = try FileManager.default.attributesOfItem(atPath: part.path)[.size] as? Int64
        #expect(size == 4_000_000)

        let handle = try FileHandle(forReadingFrom: part)
        defer { try? handle.close() }
        try handle.seek(toOffset: 3_999_999)
        #expect(try handle.read(upToCount: 1) == Data([0xAB]))
    }

    @Test("A checkpoint survives a JSON round trip")
    func checkpointRoundTrip() throws {
        let subject = TransferCheckpoint(
            url: "https://example.com/big.iso",
            totalBytes: 209_715_199,
            validator: "\"c800000-18c50a1dbc9c8390\"",
            supportsResume: true,
            isSequential: true,
            completed: [0...1_023, 4_096...8_191]
        )
        let data = try Download.makeEncoder().encode(subject)
        let decoded = try Download.makeDecoder().decode(TransferCheckpoint.self, from: data)
        #expect(decoded == subject)
        #expect(decoded.completedRanges == [0...1_023, 4_096...8_191])
    }
}
