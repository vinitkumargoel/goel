import XCTest
@testable import GoelCore

final class HLSRemediationTests: XCTestCase {

    private let base = URL(string: "https://cdn.example.com/video/index.m3u8")!

    private func task() -> DownloadTask {
        DownloadTask(source: .hlsStream(URL(string: "https://cdn.example.com/video/index.m3u8")!),
                     name: "stream.mp4", saveDirectory: NSTemporaryDirectory())
    }

    func testIntMaxByteRangeIsRejectedInsteadOfTrapping() {
        let text = """
        #EXTM3U
        #EXTINF:4.0,
        #EXT-X-BYTERANGE:9223372036854775807@9223372036854775807
        stream.mp4
        """
        XCTAssertNil(HLSParser.parse(text, baseURL: base),
                     "an unbounded BYTERANGE must be a clean parse failure, never an overflow trap")
    }

    func testIntMaxMapByteRangeIsRejectedInsteadOfTrapping() {
        let text = """
        #EXTM3U
        #EXT-X-MAP:URI="stream.mp4",BYTERANGE="9223372036854775807@9223372036854775807"
        #EXTINF:4.0,
        stream.mp4
        """
        XCTAssertNil(HLSParser.parse(text, baseURL: base))
    }

    func testHugeButParseableByteRangeIsRejected() {
        let text = """
        #EXTM3U
        #EXTINF:4.0,
        #EXT-X-BYTERANGE:1024@4503599627370496
        stream.mp4
        """
        XCTAssertNil(HLSParser.parse(text, baseURL: base))
    }

    func testMalformedByteRangeOffsetIsRejectedNotSilentlyReplaced() {
        let text = """
        #EXTM3U
        #EXT-X-MAP:URI="stream.mp4",BYTERANGE="1184@0"
        #EXTINF:4.0,
        #EXT-X-BYTERANGE:501760@abc
        stream.mp4
        """
        XCTAssertNil(HLSParser.parse(text, baseURL: base),
                     "a malformed offset must not silently resolve to the previous range's end")
    }

    func testNegativeAndZeroLengthByteRangesAreRejected() {
        for value in ["-1", "0", "1024@-4096"] {
            let text = """
            #EXTM3U
            #EXTINF:4.0,
            #EXT-X-BYTERANGE:\(value)
            stream.mp4
            """
            XCTAssertNil(HLSParser.parse(text, baseURL: base), "BYTERANGE:\(value) must not parse")
        }
    }

    func testOrdinaryByteRangesStillParse() {
        let text = """
        #EXTM3U
        #EXT-X-MAP:URI="stream.mp4",BYTERANGE="1184@0"
        #EXTINF:4.0,
        #EXT-X-BYTERANGE:501760@1184
        stream.mp4
        #EXTINF:4.0,
        #EXT-X-BYTERANGE:498688
        stream.mp4
        """
        guard case .media(let segs, let map, _, _)? = HLSParser.parse(text, baseURL: base) else {
            return XCTFail("expected media playlist")
        }
        XCTAssertEqual(map?.byteRange, HLSByteRange(start: 0, length: 1184))
        XCTAssertEqual(segs[1].byteRange, HLSByteRange(start: 1184 + 501760, length: 498688))
    }

    func testIntMaxMediaSequenceIsRejectedInsteadOfTrapping() {
        let text = """
        #EXTM3U
        #EXT-X-MEDIA-SEQUENCE:9223372036854775807
        #EXTINF:1.0,
        a.ts
        """
        XCTAssertNil(HLSParser.parse(text, baseURL: base))
    }

    /// RFC 8216 §4.3.3.2: MEDIA-SEQUENCE is a decimal-integer, never negative, and it feeds AES-128 IV derivation.
    func testNegativeOrNonNumericMediaSequenceIsRejected() {
        for value in ["-1", "abc"] {
            let text = """
            #EXTM3U
            #EXT-X-MEDIA-SEQUENCE:\(value)
            #EXTINF:1.0,
            a.ts
            """
            XCTAssertNil(HLSParser.parse(text, baseURL: base), "MEDIA-SEQUENCE:\(value) must not parse")
        }
    }

    func testOrdinaryMediaSequenceStillSeedsTheSegmentNumbers() {
        let text = """
        #EXTM3U
        #EXT-X-MEDIA-SEQUENCE:42
        #EXTINF:1.0,
        a.ts
        #EXTINF:1.0,
        b.ts
        """
        guard case .media(let segs, _, _, _)? = HLSParser.parse(text, baseURL: base) else {
            return XCTFail("expected media playlist")
        }
        XCTAssertEqual(segs.map(\.sequence), [42, 43])
    }

    /// `Double("inf")`, `"nan"` and `"1e400"` all parse in Swift, and the poisoned total then traps the `Int64` estimate.
    func testNonFiniteSegmentDurationsAreClampedNotPropagated() {
        for value in ["inf", "-inf", "nan", "1e400"] {
            let text = """
            #EXTM3U
            #EXTINF:\(value),
            a.ts
            """
            guard case .media(_, _, _, let total)? = HLSParser.parse(text, baseURL: base) else {
                return XCTFail("expected media playlist for EXTINF:\(value)")
            }
            XCTAssertTrue(total.isFinite, "EXTINF:\(value) must not poison the total duration")
            XCTAssertEqual(total, 0, accuracy: 0.0001)
        }
    }

    func testAbsurdSegmentDurationIsClampedAndOrdinaryOnesSurvive() {
        guard case .media(_, _, _, let absurd)? =
                HLSParser.parse("#EXTM3U\n#EXTINF:99999999,\na.ts", baseURL: base),
              case .media(_, _, _, let normal)? =
                HLSParser.parse("#EXTM3U\n#EXTINF:9.009,\na.ts", baseURL: base) else {
            return XCTFail("expected media playlists")
        }
        XCTAssertEqual(absurd, 0, accuracy: 0.0001)
        XCTAssertEqual(normal, 9.009, accuracy: 0.0001)
    }

    func testEstimatedBytesRefusesNonFiniteInput() {
        XCTAssertEqual(HLSEngine.estimatedBytes(bandwidth: 1_000_000, duration: .infinity), 0)
        XCTAssertEqual(HLSEngine.estimatedBytes(bandwidth: 1_000_000, duration: .nan), 0)
        XCTAssertEqual(HLSEngine.estimatedBytes(bandwidth: 1_000_000, duration: -5), 0)
        XCTAssertEqual(HLSEngine.estimatedBytes(bandwidth: 0, duration: 10), 0)
        XCTAssertEqual(HLSEngine.estimatedBytes(bandwidth: Int.max, duration: 1e300), 0)
        XCTAssertEqual(HLSEngine.estimatedBytes(bandwidth: 8_000_000, duration: 10), 10_000_000)
    }

    /// An unrecognised METHOD collapsing to `.none` writes ciphertext to disk and reports it as completed.
    func testUnrecognisedKeyMethodIsUnsupportedNotUnencrypted() {
        for method in ["SAMPLE-AES", "SAMPLE-AES-CTR", "AES-256"] {
            let text = """
            #EXTM3U
            #EXT-X-KEY:METHOD=\(method),URI="key.bin"
            #EXTINF:4.0,
            a.ts
            """
            guard case .media(let segs, _, _, _)? = HLSParser.parse(text, baseURL: base) else {
                return XCTFail("expected media playlist for METHOD=\(method)")
            }
            XCTAssertEqual(segs[0].key?.method, .unsupported(method),
                           "\(method) must not be treated as unencrypted")
        }
    }

    /// A non-`identity` KEYFORMAT is DRM: the URI is a licence endpoint, not key material.
    func testDRMKeyFormatIsReportedUnsupported() {
        let text = """
        #EXTM3U
        #EXT-X-KEY:METHOD=AES-128,URI="skd://key/123",KEYFORMAT="com.apple.streamingkeydelivery"
        #EXTINF:4.0,
        a.ts
        """
        guard case .media(let segs, _, _, _)? = HLSParser.parse(text, baseURL: base),
              case .unsupported(let reason)? = segs[0].key?.method else {
            return XCTFail("a DRM key must parse as an unsupported method")
        }
        XCTAssertTrue(reason.contains("com.apple.streamingkeydelivery"))
        XCTAssertNil(segs[0].key?.url, "a licence endpoint must never be fetched as a key")
    }

    func testPlainAES128AndNoneAreUnaffected() {
        let aes = """
        #EXTM3U
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin",KEYFORMAT="identity"
        #EXTINF:4.0,
        a.ts
        """
        let none = """
        #EXTM3U
        #EXT-X-KEY:METHOD=NONE
        #EXTINF:4.0,
        a.ts
        """
        guard case .media(let encrypted, _, _, _)? = HLSParser.parse(aes, baseURL: base),
              case .media(let plain, _, _, _)? = HLSParser.parse(none, baseURL: base) else {
            return XCTFail("expected media playlists")
        }
        XCTAssertEqual(encrypted[0].key?.method, .aes128)
        XCTAssertEqual(encrypted[0].key?.url?.absoluteString, "https://cdn.example.com/video/key.bin")
        XCTAssertNil(plain[0].key)
    }

    /// RFC 8216 §4.3.2.5: an `#EXT-X-MAP`'s key is the most recent one *preceding* it, not the first segment's.
    func testInitMapCarriesThePrecedingKeyOnly() {
        let keyed = """
        #EXTM3U
        #EXT-X-KEY:METHOD=AES-128,URI="k1.bin",IV=0x00000000000000000000000000000001
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:4.0,
        a.m4s
        """
        let unkeyed = """
        #EXTM3U
        #EXT-X-MAP:URI="init.mp4"
        #EXT-X-KEY:METHOD=AES-128,URI="k1.bin"
        #EXTINF:4.0,
        a.m4s
        """
        guard case .media(_, let keyedMap, _, _)? = HLSParser.parse(keyed, baseURL: base),
              case .media(let segs, let unkeyedMap, _, _)? = HLSParser.parse(unkeyed, baseURL: base) else {
            return XCTFail("expected media playlists")
        }
        XCTAssertEqual(keyedMap?.key?.method, .aes128)
        XCTAssertNotNil(keyedMap?.key?.iv, "an encrypted map must carry its explicit IV")
        XCTAssertNil(unkeyedMap?.key, "a map preceding every EXT-X-KEY is plaintext")
        XCTAssertEqual(segs[0].key?.method, .aes128)
    }

    /// `URLSession` services `file://` data tasks, so an absolute non-web URI reads local bytes into the output.
    func testNonWebSegmentURIRejectsThePlaylist() {
        let text = """
        #EXTM3U
        #EXTINF:4.0,
        file:///etc/passwd
        """
        XCTAssertNil(HLSParser.parse(text, baseURL: base))
    }

    func testNonWebKeyURIIsNotResolved() {
        let text = """
        #EXTM3U
        #EXT-X-KEY:METHOD=AES-128,URI="file:///etc/passwd"
        #EXTINF:4.0,
        a.ts
        """
        guard case .media(let segs, _, _, _)? = HLSParser.parse(text, baseURL: base) else {
            return XCTFail("expected media playlist")
        }
        XCTAssertNil(segs[0].key?.url, "a file:// key URI must not resolve")
    }

    /// An unresolvable init-map URI leaving `map` nil silently switches fMP4 concat to the MPEG-TS remux path.
    func testUnresolvableInitMapURIRejectsThePlaylist() {
        let bad = """
        #EXTM3U
        #EXT-X-MAP:URI="file:///tmp/init.mp4"
        #EXTINF:4.0,
        a.m4s
        """
        let missing = """
        #EXTM3U
        #EXT-X-MAP:BYTERANGE="1184@0"
        #EXTINF:4.0,
        a.m4s
        """
        XCTAssertNil(HLSParser.parse(bad, baseURL: base))
        XCTAssertNil(HLSParser.parse(missing, baseURL: base))
    }

    /// Master playlists stay lenient on purpose: one unusable rendition must still leave the others.
    func testUnresolvableVariantURIOnlyDropsThatVariant() {
        let text = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360
        file:///tmp/360.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720
        720/index.m3u8
        """
        guard case .master(let variants)? = HLSParser.parse(text, baseURL: base) else {
            return XCTFail("expected master playlist")
        }
        XCTAssertEqual(variants.count, 1)
        XCTAssertEqual(variants[0].height, 720)
    }

    func testIsFinishedDistinguishesVODFromLive() {
        let live = """
        #EXTM3U
        #EXT-X-TARGETDURATION:6
        #EXTINF:6.0,
        a.ts
        """
        XCTAssertFalse(HLSParser.isFinished(live),
                       "a playlist with neither ENDLIST nor PLAYLIST-TYPE:VOD is live")
        XCTAssertTrue(HLSParser.isFinished(live + "\n#EXT-X-ENDLIST"))
        XCTAssertTrue(HLSParser.isFinished("#EXTM3U\n#EXT-X-PLAYLIST-TYPE:VOD\n" + live))
    }

    func testSeparateAudioRenditionIsFlaggedOnTheVariant() {
        let text = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="English",DEFAULT=YES,URI="audio/en.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=1280x720,CODECS="avc1.4d401f",AUDIO="aac"
        video/720.m3u8
        """
        guard case .master(let variants)? = HLSParser.parse(text, baseURL: base) else {
            return XCTFail("expected master playlist")
        }
        XCTAssertEqual(variants[0].audioGroupID, "aac")
        XCTAssertTrue(variants[0].hasSeparateAudio)
        XCTAssertFalse(HLSParser.declaresAudioCodec(variants[0].codecs),
                       "the variant declares no audio codec, so it would play silent")
    }

    /// RFC 8216 §4.3.4.1: a rendition with no URI is already muxed into the variants that name its group.
    func testAudioRenditionWithoutURIIsNotTreatedAsSeparate() {
        let text = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="English",DEFAULT=YES
        #EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="aac"
        video/720.m3u8
        """
        guard case .master(let variants)? = HLSParser.parse(text, baseURL: base) else {
            return XCTFail("expected master playlist")
        }
        XCTAssertFalse(variants[0].hasSeparateAudio)
    }

    func testDeclaresAudioCodecRecognisesMuxedAudio() {
        XCTAssertTrue(HLSParser.declaresAudioCodec("avc1.4d401f,mp4a.40.2"))
        XCTAssertTrue(HLSParser.declaresAudioCodec("hvc1.1.6.L93.B0, ec-3"))
        XCTAssertFalse(HLSParser.declaresAudioCodec("avc1.4d401f"))
        XCTAssertFalse(HLSParser.declaresAudioCodec(nil))
    }

    func testEngineSessionStripsCredentialsOnCrossHostRedirect() {
        let engine = HLSEngine(profile: .high)
        XCTAssertTrue(engine.session.delegate is RedirectSanitizer,
                      "HLS fetches carry the task's cookie/auth headers; a 30x must not replay them")
    }

    func testRangeHeaderIsOmittedRatherThanOverflowing() {
        let engine = HLSEngine(profile: .high)
        let url = URL(string: "https://cdn.example.com/video/stream.mp4")!
        let overflowing = engine.makeRequest(url, task: task(),
                                             range: HLSByteRange(start: Int.max, length: 8))
        XCTAssertNil(overflowing.value(forHTTPHeaderField: "Range"))

        let empty = engine.makeRequest(url, task: task(), range: HLSByteRange(start: 100, length: 0))
        XCTAssertNil(empty.value(forHTTPHeaderField: "Range"),
                     "a zero-length range would ask for the nonsense `bytes=100-99`")

        let ordinary = engine.makeRequest(url, task: task(), range: HLSByteRange(start: 100, length: 50))
        XCTAssertEqual(ordinary.value(forHTTPHeaderField: "Range"), "bytes=100-149")
    }
}
