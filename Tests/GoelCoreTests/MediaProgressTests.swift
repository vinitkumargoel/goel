import XCTest
import Foundation
@testable import GoelCore

/// Tests for the media-conversion logic: reading ffmpeg's progress stream and
/// its banner, deriving percentage and ETA, sizing an audio extraction, and
/// deciding whether a stream copy is worth attempting.
///
/// Every case runs against fixture strings captured from real ffmpeg output. No
/// process is spawned — that is the whole reason this logic lives in `GoelCore`
/// as pure functions while `GoelApp` owns the process plumbing. A test that
/// needed ffmpeg installed would be skipped on CI and would therefore protect
/// nothing.
final class MediaProgressTests: XCTestCase {

    // MARK: - Progress blocks

    /// A complete block, exactly as ffmpeg writes it with `-progress pipe:1`.
    private let oneBlock = """
    bitrate=1955.3kbits/s
    total_size=41582592
    out_time_us=252480000
    out_time_ms=252480000
    out_time=00:04:12.480000
    speed=1.83x
    progress=continue

    """

    func testCompleteBlockIsParsed() {
        var reader = MediaProgressReader()
        let samples = reader.consume(oneBlock)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].outTimeSeconds ?? 0, 252.48, accuracy: 0.001)
        XCTAssertEqual(samples[0].totalSize, 41_582_592)
        XCTAssertEqual(samples[0].speed ?? 0, 1.83, accuracy: 0.001)
        XCTAssertFalse(samples[0].isFinal)
    }

    /// The realistic failure mode: a pipe read lands mid-line. Splitting on
    /// newlines and parsing each chunk independently drops or mangles roughly
    /// every other reading, which is why the reader carries a tail.
    func testBlockSplitAcrossReadsIsStitchedBackTogether() {
        var reader = MediaProgressReader()
        let midpoint = oneBlock.index(oneBlock.startIndex, offsetBy: 47)
        let first = String(oneBlock[oneBlock.startIndex..<midpoint])
        let second = String(oneBlock[midpoint...])

        XCTAssertTrue(reader.consume(first).isEmpty, "no block has completed yet")
        let samples = reader.consume(second)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(samples[0].outTimeSeconds ?? 0, 252.48, accuracy: 0.001)
        XCTAssertEqual(samples[0].totalSize, 41_582_592)
    }

    /// Split at every single character boundary: the reader must produce exactly
    /// one sample no matter where the chunk edges fall.
    func testAnySplitPointYieldsExactlyOneSample() {
        for offset in 0...oneBlock.count {
            var reader = MediaProgressReader()
            let cut = oneBlock.index(oneBlock.startIndex, offsetBy: offset)
            var samples = reader.consume(String(oneBlock[oneBlock.startIndex..<cut]))
            samples += reader.consume(String(oneBlock[cut...]))
            XCTAssertEqual(samples.count, 1, "split at \(offset) produced \(samples.count) samples")
            XCTAssertEqual(samples.first?.totalSize, 41_582_592, "split at \(offset) lost a field")
        }
    }

    func testSeveralBlocksInOneChunk() {
        var reader = MediaProgressReader()
        let samples = reader.consume(oneBlock + oneBlock + oneBlock)
        XCTAssertEqual(samples.count, 3)
    }

    /// `progress=end` marks the last block, which the UI uses to snap the bar to
    /// 100% rather than leaving it at whatever the final reading happened to be.
    func testFinalBlockIsFlagged() {
        var reader = MediaProgressReader()
        let samples = reader.consume("""
        out_time_us=662000000
        progress=end

        """)
        XCTAssertEqual(samples.count, 1)
        XCTAssertTrue(samples[0].isFinal)
    }

    /// ffmpeg writes "N/A" for everything until the first frame is muxed. Those
    /// must not become zeroes — a zero reads as real progress.
    func testNotAvailableValuesAreIgnored() {
        var reader = MediaProgressReader()
        let samples = reader.consume("""
        out_time_us=N/A
        out_time=N/A
        speed=N/A
        progress=continue

        """)
        XCTAssertEqual(samples.count, 0, "a block with nothing usable in it emits nothing")
    }

    /// `out_time_ms` is a long-standing ffmpeg misnomer: it carries microseconds
    /// despite the name. Reading it as milliseconds reports progress 1000× fast,
    /// which parks the bar at 100% within the first second of every job.
    func testOutTimeMsIsTreatedAsMicroseconds() {
        var reader = MediaProgressReader()
        let samples = reader.consume("out_time_ms=90000000\nprogress=continue\n")
        XCTAssertEqual(samples.first?.outTimeSeconds ?? 0, 90, accuracy: 0.001)
    }

    /// When only the timecode form is present it is used; when both are present
    /// the microsecond value wins and the timecode does not overwrite it.
    func testTimecodeIsUsedOnlyAsFallback() {
        var reader = MediaProgressReader()
        let fallback = reader.consume("out_time=00:01:30.500000\nprogress=continue\n")
        XCTAssertEqual(fallback.first?.outTimeSeconds ?? 0, 90.5, accuracy: 0.001)

        var precise = MediaProgressReader()
        let both = precise.consume("out_time_us=90000000\nout_time=00:99:99.0\nprogress=continue\n")
        XCTAssertEqual(both.first?.outTimeSeconds ?? 0, 90, accuracy: 0.001)
    }

    func testTimecodeFormats() {
        XCTAssertEqual(MediaProgressReader.seconds(fromTimecode: "01:02:03.5") ?? 0, 3723.5, accuracy: 0.001)
        XCTAssertEqual(MediaProgressReader.seconds(fromTimecode: "02:03") ?? 0, 123, accuracy: 0.001)
        XCTAssertEqual(MediaProgressReader.seconds(fromTimecode: "42.25") ?? 0, 42.25, accuracy: 0.001)
        XCTAssertNil(MediaProgressReader.seconds(fromTimecode: "N/A"))
        XCTAssertNil(MediaProgressReader.seconds(fromTimecode: ""))
        XCTAssertNil(MediaProgressReader.seconds(fromTimecode: "1:2:3:4"))
        XCTAssertNil(MediaProgressReader.seconds(fromTimecode: "not a time"))
    }

    // MARK: - Banner

    private let banner = """
    Input #0, mov,mp4,m4a,3gp,3g2,mj2, from 'lecture.mp4':
      Metadata:
        major_brand     : isom
      Duration: 00:11:02.34, start: 0.000000, bitrate: 1955 kb/s
      Stream #0:0[0x1](und): Video: h264 (High) (avc1 / 0x31637661), yuv420p, 1920x1080, 1824 kb/s, 30 fps
      Stream #0:1[0x2](und): Audio: aac (LC) (mp4a / 0x6134706D), 44100 Hz, stereo, fltp, 128 kb/s
    At least one output file must be specified
    """

    func testDurationIsReadFromBanner() {
        XCTAssertEqual(MediaDuration.parse(banner: banner) ?? 0, 662.34, accuracy: 0.01)
    }

    /// A live stream reports no length. That must stay nil — a zero would read as
    /// "instant" and put the bar at 100% before anything had happened.
    func testUnknownDurationStaysNil() {
        XCTAssertNil(MediaDuration.parse(banner: "  Duration: N/A, start: 0.000000, bitrate: N/A"))
        XCTAssertNil(MediaDuration.parse(banner: "no duration line here at all"))
        XCTAssertNil(MediaDuration.parse(banner: ""))
    }

    func testAudioCodecIsReadFromBanner() {
        XCTAssertEqual(MediaDuration.audioCodec(banner: banner), "aac")
    }

    /// A silent video has no audio stream. Answering nil rather than guessing lets
    /// the caller re-encode (always correct) instead of attempting a copy that
    /// cannot work.
    func testNoAudioStreamYieldsNil() {
        let silent = """
          Duration: 00:00:30.00, start: 0.000000, bitrate: 900 kb/s
          Stream #0:0[0x1]: Video: h264 (High), yuv420p, 1280x720, 30 fps
        """
        XCTAssertNil(MediaDuration.audioCodec(banner: silent))
    }

    func testAudioCodecIgnoresLinesThatAreNotStreams() {
        // "Audio: " appearing in a metadata comment must not be mistaken for a
        // stream declaration.
        let noisy = """
            comment         : Audio: remastered
          Stream #0:1: Audio: flac, 48000 Hz, stereo
        """
        XCTAssertEqual(MediaDuration.audioCodec(banner: noisy), "flac")
    }

    // MARK: - Fraction and ETA

    func testFractionIsClampedToOne() {
        // Container durations run a few tenths short of the real stream, so an
        // unclamped ratio parks at "103%" for the last second of every job.
        XCTAssertEqual(MediaEstimate.fraction(processed: 700, total: 662) ?? 0, 1, accuracy: 0.0001)
        XCTAssertEqual(MediaEstimate.fraction(processed: 331, total: 662) ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(MediaEstimate.fraction(processed: 0, total: 662) ?? -1, 0, accuracy: 0.0001)
    }

    func testFractionIsNilWithoutAKnownTotal() {
        XCTAssertNil(MediaEstimate.fraction(processed: 100, total: nil))
        XCTAssertNil(MediaEstimate.fraction(processed: 100, total: 0))
        XCTAssertNil(MediaEstimate.fraction(processed: 100, total: -5))
    }

    func testEtaUsesFfmpegsOwnSpeed() {
        // 662 - 300 = 362 media-seconds left at 2× real time.
        let eta = MediaEstimate.eta(processed: 300, total: 662, speed: 2)
        XCTAssertEqual(eta ?? 0, 181, accuracy: 0.01)
    }

    /// "∞ remaining" and "0s remaining" are both noise; the UI should omit the
    /// clause entirely rather than print a placeholder.
    func testEtaIsNilWhenThereIsNothingHonestToSay() {
        XCTAssertNil(MediaEstimate.eta(processed: 0, total: 662, speed: nil), "no speed yet")
        XCTAssertNil(MediaEstimate.eta(processed: 0, total: 662, speed: 0), "stalled at zero")
        XCTAssertNil(MediaEstimate.eta(processed: 100, total: nil, speed: 2), "unknown length")
        XCTAssertNil(MediaEstimate.eta(processed: 662, total: 662, speed: 2), "already finished")
        XCTAssertNil(MediaEstimate.eta(processed: 700, total: 662, speed: 2), "overshot")
    }

    // MARK: - Audio formats

    func testEstimatedSizesAreInTheRightOrderOfMagnitude() {
        let tenMinutes: Double = 600
        let mp3 = AudioExtractionFormat.mp3.estimatedBytes(durationSeconds: tenMinutes) ?? 0
        let m4a = AudioExtractionFormat.m4a.estimatedBytes(durationSeconds: tenMinutes) ?? 0
        let flac = AudioExtractionFormat.flac.estimatedBytes(durationSeconds: tenMinutes) ?? 0
        let wav = AudioExtractionFormat.wav.estimatedBytes(durationSeconds: tenMinutes) ?? 0

        // ~14 MB for ten minutes of 190 kbit/s MP3.
        XCTAssertEqual(Double(mp3), 14_400_000, accuracy: 100_000)
        XCTAssertEqual(m4a, mp3, "both lossy targets sit at the same bitrate")
        XCTAssertGreaterThan(flac, mp3 * 3, "FLAC is several times a lossy stream")
        XCTAssertGreaterThan(wav, flac, "uncompressed PCM is the largest")
        // The whole point of the hint: WAV is nearly an order of magnitude bigger
        // than MP3, and that used to be invisible until the file landed.
        XCTAssertGreaterThan(Double(wav) / Double(mp3), 6)
    }

    func testEstimatedSizeIsNilWithoutADuration() {
        XCTAssertNil(AudioExtractionFormat.wav.estimatedBytes(durationSeconds: nil))
        XCTAssertNil(AudioExtractionFormat.wav.estimatedBytes(durationSeconds: 0))
    }

    func testCopyIsOfferedOnlyForAMatchingSourceCodec() {
        XCTAssertTrue(AudioExtractionFormat.m4a.canCopy(sourceCodec: "aac"))
        XCTAssertTrue(AudioExtractionFormat.m4a.canCopy(sourceCodec: "ALAC"), "case-insensitive")
        XCTAssertTrue(AudioExtractionFormat.mp3.canCopy(sourceCodec: "mp3"))
        XCTAssertTrue(AudioExtractionFormat.flac.canCopy(sourceCodec: "flac"))

        XCTAssertFalse(AudioExtractionFormat.mp3.canCopy(sourceCodec: "aac"))
        XCTAssertFalse(AudioExtractionFormat.flac.canCopy(sourceCodec: "aac"))
    }

    /// The trap this gate exists for: ffmpeg's WAV muxer accepts an MP3 stream, so
    /// an unconditional `-acodec copy` hands back a `.wav` that is really an MP3
    /// in disguise. Only true PCM may be copied into WAV.
    func testWavRefusesToCopyALossyStream() {
        XCTAssertFalse(AudioExtractionFormat.wav.canCopy(sourceCodec: "mp3"))
        XCTAssertFalse(AudioExtractionFormat.wav.canCopy(sourceCodec: "aac"))
        XCTAssertFalse(AudioExtractionFormat.wav.canCopy(sourceCodec: "pcm_s24le"),
                       "a different sample format still needs converting")
        XCTAssertTrue(AudioExtractionFormat.wav.canCopy(sourceCodec: "pcm_s16le"))
    }

    /// Unknown means "don't assume": the caller re-encodes, which is always
    /// correct if not always fastest.
    func testUnknownCodecNeverClaimsCopyability() {
        for format in AudioExtractionFormat.allCases {
            XCTAssertFalse(format.canCopy(sourceCodec: nil))
            XCTAssertFalse(format.canCopy(sourceCodec: ""))
            XCTAssertFalse(format.canCopy(sourceCodec: "   "))
        }
    }

    // MARK: - Containers

    func testLikelyStreamCopyAcrossTheCommonContainers() {
        XCTAssertTrue(MediaContainer.likelyStreamCopy(from: "mp4", to: "mkv"))
        XCTAssertTrue(MediaContainer.likelyStreamCopy(from: "mov", to: "mp4"))
        XCTAssertTrue(MediaContainer.likelyStreamCopy(from: "MP4", to: "MKV"), "case-insensitive")
        XCTAssertTrue(MediaContainer.likelyStreamCopy(from: "webm", to: "webm"), "same container")
        // WebM takes only VP8/VP9/AV1 + Opus/Vorbis, so crossing into or out of it
        // is a re-encode far more often than not — labelling it "instant" would be
        // a promise the conversion cannot keep.
        XCTAssertFalse(MediaContainer.likelyStreamCopy(from: "mp4", to: "webm"))
        XCTAssertFalse(MediaContainer.likelyStreamCopy(from: "webm", to: "mp4"))
    }

    func testCodecIncompatibilityIsRecognised() {
        let muxerRefusals = [
            "[mp4 @ 0x14e8] Could not find tag for codec vorbis in stream #1",
            "[webm @ 0x600] Only VP8 or VP9 or AV1 video and Vorbis or Opus audio and WebVTT subtitles are supported for WebM.",
            "Could not write header for output file #0 (incorrect codec parameters ?): Invalid argument\nAutomatic encoder selection failed",
        ]
        for message in muxerRefusals {
            XCTAssertTrue(MediaContainer.isCodecIncompatibility(message),
                          "should retry as a re-encode: \(message.prefix(40))")
        }
    }

    /// Retrying *every* failure would turn a five-second error on a truncated
    /// source into a twenty-minute re-encode that fails the same way at the end.
    func testOtherFailuresDoNotTriggerAReEncodeRetry() {
        let realFailures = [
            "lecture.mp4: No such file or directory",
            "[mp4 @ 0x14e8] moov atom not found",
            "Error while opening encoder — no space left on device",
            "",
        ]
        for message in realFailures {
            XCTAssertFalse(MediaContainer.isCodecIncompatibility(message),
                           "should NOT retry: \(message)")
        }
    }

    // MARK: - Stall detection

    func testStallIsFlaggedOnlyAfterTheThreshold() {
        let now = Date()
        let justBefore = now.addingTimeInterval(-(MediaStall.threshold - 1))
        let justAfter = now.addingTimeInterval(-(MediaStall.threshold + 1))
        XCTAssertFalse(MediaStall.isStalled(lastAdvance: now, now: now))
        XCTAssertFalse(MediaStall.isStalled(lastAdvance: justBefore, now: now))
        XCTAssertTrue(MediaStall.isStalled(lastAdvance: justAfter, now: now))
    }

    /// The threshold has to be well under the 30-minute blind kill it replaces —
    /// flagging a wedge 25 minutes earlier is most of the point.
    func testStallThresholdIsFarShorterThanTheOldWatchdog() {
        XCTAssertLessThan(MediaStall.threshold, 30 * 60)
        XCTAssertGreaterThanOrEqual(MediaStall.threshold, 60,
                                    "long enough that a slow single frame isn't called stuck")
    }

    // MARK: - Stuck cancels

    func testStopIsNotCalledStuckUntilSigkillHasHadItsChance() {
        let now = Date()
        XCTAssertFalse(MediaStall.isStopStuck(requestedAt: now, now: now))
        XCTAssertFalse(MediaStall.isStopStuck(
            requestedAt: now.addingTimeInterval(-(MediaStall.stopGrace - 1)), now: now))
        XCTAssertTrue(MediaStall.isStopStuck(
            requestedAt: now.addingTimeInterval(-(MediaStall.stopGrace + 1)), now: now))
    }

    /// The grace has to outlast the app's own SIGTERM → 2s → SIGKILL escalation,
    /// or a perfectly ordinary stop would be reported as broken while it works.
    func testStopGraceOutlastsTheKillEscalation() {
        XCTAssertGreaterThan(MediaStall.stopGrace, 2,
                             "shorter than the SIGTERM grace would flag every cancel")
        XCTAssertLessThan(MediaStall.stopGrace, 60,
                          "a minute staring at “Stopping…” is the dead end this replaces")
    }

    // MARK: - Settings

    /// A hand-edited 0 or negative in the settings file would leave the queue with
    /// jobs that can never start.
    func testMediaConcurrencyIsClampedOnDecode() throws {
        let json = #"{"mediaConcurrency": 0}"#.data(using: .utf8)!
        let settings = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(settings.mediaConcurrency, 1)

        let negative = #"{"mediaConcurrency": -4}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: negative).mediaConcurrency, 1)

        let absent = #"{}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: absent).mediaConcurrency, 2,
                       "an older settings file gets the default")
    }
}
