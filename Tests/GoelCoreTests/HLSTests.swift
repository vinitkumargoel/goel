// AVFoundation and CommonCrypto are macOS-only, so these fixtures cannot build on Linux.
#if !os(Linux)
import XCTest
import AVFoundation
import CommonCrypto
@testable import GoelCore

final class HLSTests: XCTestCase {

    private let base = URL(string: "https://cdn.example.com/video/index.m3u8")!
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goel-hls-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    func testLiveHLSDownloadProducesPlayableMP4() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["GOEL_LIVE_NET"] == "1",
                          "set GOEL_LIVE_NET=1 to run the live network test")
        let url = URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_4x3/gear1/prog_index.m3u8")!
        let engine = HLSEngine(profile: .high)
        let task = DownloadTask(source: .hlsStream(url), name: "bipbop.mp4", saveDirectory: tempDir.path)
        let stream = engine.events(for: task.id)
        await engine.add(task)

        var failure: DownloadError?
        var completed = false
        let waiter = Task { () -> Void in
            for await event in stream {
                if case .failed(let e) = event { failure = e; break }
                if case .statusChanged(.completed) = event { completed = true; break }
            }
        }
        _ = await waiter.value

        XCTAssertNil(failure, "live HLS download must not fail: \(String(describing: failure))")
        XCTAssertTrue(completed, "live HLS download should reach .completed")

        let out = tempDir.appendingPathComponent("bipbop.mp4")
        let size = ((try? FileManager.default.attributesOfItem(atPath: out.path)[.size]) as? Int64) ?? 0
        XCTAssertGreaterThan(size, 1_000_000, "output MP4 should be a few MB")

        let asset = AVURLAsset(url: out)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertFalse(tracks.isEmpty, "remuxed MP4 must contain a video track")
    }

    func testParseMasterPlaylistVariants() {
        let text = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.4d401e,mp4a.40.2"
        360/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=2400000,RESOLUTION=1280x720
        720/index.m3u8
        """
        guard case .master(let variants)? = HLSParser.parse(text, baseURL: base) else {
            return XCTFail("expected master playlist")
        }
        XCTAssertEqual(variants.count, 2)
        XCTAssertEqual(variants[0].bandwidth, 800_000)
        XCTAssertEqual(variants[0].height, 360)
        XCTAssertEqual(variants[0].codecs, "avc1.4d401e,mp4a.40.2")
        XCTAssertEqual(variants[1].height, 720)
        XCTAssertEqual(variants[0].url.absoluteString, "https://cdn.example.com/video/360/index.m3u8")
    }

    func testSelectVariantRespectsHeightCapThenBandwidth() {
        let v = [
            HLSVariant(url: base, bandwidth: 800_000, height: 360, codecs: nil),
            HLSVariant(url: base, bandwidth: 2_400_000, height: 720, codecs: nil),
            HLSVariant(url: base, bandwidth: 6_000_000, height: 1080, codecs: nil),
        ]
        XCTAssertEqual(HLSParser.selectVariant(v, maxHeight: 720)?.height, 720)
        XCTAssertEqual(HLSParser.selectVariant(v, maxHeight: nil)?.height, 1080)
        XCTAssertEqual(HLSParser.selectVariant(v, maxHeight: 240)?.height, 1080,
                       "no variant under the cap → fall back to highest bandwidth")
    }

    func testParseMediaPlaylistSegments() {
        let text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:10
        #EXT-X-MEDIA-SEQUENCE:0
        #EXTINF:9.009,
        seg0.ts
        #EXTINF:9.009,
        seg1.ts
        #EXTINF:3.003,
        https://other.cdn/seg2.ts
        #EXT-X-ENDLIST
        """
        guard case .media(let segs, let mapURL, let target, let total)? = HLSParser.parse(text, baseURL: base) else {
            return XCTFail("expected media playlist")
        }
        XCTAssertNil(mapURL)
        XCTAssertEqual(target, 10)
        XCTAssertEqual(segs.count, 3)
        XCTAssertEqual(segs[0].sequence, 0)
        XCTAssertEqual(segs[1].sequence, 1)
        XCTAssertEqual(segs[0].url.absoluteString, "https://cdn.example.com/video/seg0.ts")
        XCTAssertEqual(segs[2].url.absoluteString, "https://other.cdn/seg2.ts")
        XCTAssertEqual(total, 9.009 + 9.009 + 3.003, accuracy: 0.001)
    }

    func testParseMediaPlaylistAES128Key() {
        let text = """
        #EXTM3U
        #EXT-X-MEDIA-SEQUENCE:5
        #EXT-X-KEY:METHOD=AES-128,URI="https://keys.example.com/k1.bin",IV=0x00000000000000000000000000000005
        #EXTINF:6.0,
        seg5.ts
        """
        guard case .media(let segs, _, _, _)? = HLSParser.parse(text, baseURL: base) else {
            return XCTFail("expected media playlist")
        }
        XCTAssertEqual(segs.first?.sequence, 5)
        let key = segs.first?.key
        XCTAssertEqual(key?.method, .aes128)
        XCTAssertEqual(key?.url?.absoluteString, "https://keys.example.com/k1.bin")
        XCTAssertEqual(key?.iv?.count, 16)
        XCTAssertEqual(key?.iv?.last, 5)
    }

    func testParseKeyMethodNoneClearsEncryption() {
        let text = """
        #EXTM3U
        #EXT-X-KEY:METHOD=AES-128,URI="k.bin"
        #EXTINF:1.0,
        a.ts
        #EXT-X-KEY:METHOD=NONE
        #EXTINF:1.0,
        b.ts
        """
        guard case .media(let segs, _, _, _)? = HLSParser.parse(text, baseURL: base) else {
            return XCTFail("expected media playlist")
        }
        XCTAssertEqual(segs[0].key?.method, .aes128)
        XCTAssertNil(segs[1].key, "METHOD=NONE removes the key for later segments")
    }

    func testParseFMP4InitMap() {
        let text = """
        #EXTM3U
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:4.0,
        seg0.m4s
        """
        guard case .media(_, let map, _, _)? = HLSParser.parse(text, baseURL: base) else {
            return XCTFail("expected media playlist")
        }
        XCTAssertEqual(map?.url.absoluteString, "https://cdn.example.com/video/init.mp4")
        XCTAssertNil(map?.byteRange, "a map without BYTERANGE covers the whole resource")
    }

    /// Losing the map's `BYTERANGE` turns the init fetch into an unranged GET of the whole file.
    func testParseFMP4InitMapKeepsByteRange() {
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
        XCTAssertEqual(map?.url.absoluteString, "https://cdn.example.com/video/stream.mp4")
        XCTAssertEqual(map?.byteRange, HLSByteRange(start: 0, length: 1184))
        XCTAssertEqual(segs[0].byteRange, HLSByteRange(start: 1184, length: 501760))
        XCTAssertEqual(segs[1].byteRange, HLSByteRange(start: 1184 + 501760, length: 498688))
    }

    /// An implicit offset must start after the map's sub-range, not at byte 0, or the init header is re-read.
    func testImplicitSegmentOffsetFollowsInitMapRange() {
        let text = """
        #EXTM3U
        #EXT-X-MAP:URI="stream.mp4",BYTERANGE="800@0"
        #EXTINF:4.0,
        #EXT-X-BYTERANGE:12000
        stream.mp4
        """
        guard case .media(let segs, _, _, _)? = HLSParser.parse(text, baseURL: base) else {
            return XCTFail("expected media playlist")
        }
        XCTAssertEqual(segs[0].byteRange, HLSByteRange(start: 800, length: 12000))
    }

    func testParseRejectsNonPlaylist() {
        XCTAssertNil(HLSParser.parse("not a playlist", baseURL: base))
        XCTAssertNil(HLSParser.parse("", baseURL: base))
    }

    func testHexToDataParsesIV() {
        XCTAssertEqual(HLSParser.hexToData("0x0102")!, Data([0x01, 0x02]))
        XCTAssertEqual(HLSParser.hexToData("ABCD")!, Data([0xAB, 0xCD]))
        XCTAssertNil(HLSParser.hexToData("0x123"))
        XCTAssertNil(HLSParser.hexToData("zz"))
    }

    func testIVFromSequence() {
        let iv = HLSEngine.iv(forSequence: 5)
        XCTAssertEqual(iv.count, 16)
        XCTAssertEqual(Array(iv), [0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,5])
        XCTAssertEqual(Array(HLSEngine.iv(forSequence: 256)).suffix(2), [1, 0])
    }

    func testAES128CBCDecryptRoundTrip() throws {
        let key = Data((0..<16).map { UInt8($0) })
        let iv = Data(repeating: 0xAB, count: 16)
        let plaintext = Data("The quick brown fox jumps over the lazy dog — HLS!".utf8)

        let cipher = try Self.aes128CBCEncrypt(plaintext, key: key, iv: iv)
        XCTAssertNotEqual(cipher, plaintext)

        let decrypted = HLSEngine.aes128CBCDecrypt(cipher, key: key, iv: iv)
        XCTAssertEqual(decrypted, plaintext)
    }

    func testAES128RejectsBadKeyOrIVLength() {
        let cipher = Data(repeating: 0, count: 32)
        XCTAssertNil(HLSEngine.aes128CBCDecrypt(cipher, key: Data(repeating: 0, count: 8),
                                                iv: Data(repeating: 0, count: 16)))
        XCTAssertNil(HLSEngine.aes128CBCDecrypt(cipher, key: Data(repeating: 0, count: 16),
                                                iv: Data(repeating: 0, count: 8)))
    }

    func testParseDetectsM3U8AsHLS() {
        XCTAssertEqual(DownloadSource.parse("https://x.com/a/index.m3u8")?.kind, .hls)
        XCTAssertEqual(DownloadSource.parse("https://x.com/a/playlist.m3u8?token=abc123")?.kind, .hls,
                       "query string must not defeat detection")
        XCTAssertEqual(DownloadSource.parse("https://x.com/a/file.bin")?.kind, .http)
        XCTAssertEqual(DownloadSource.parse("https://x.com/a/x.torrent")?.kind, .torrent)
    }

    func testHLSDefaultNameDerivation() {
        XCTAssertEqual(DownloadManager.defaultName(for: .hlsStream(URL(string: "https://c/MyShow_S01E02/index.m3u8")!)),
                       "MyShow_S01E02.mp4")
        XCTAssertEqual(DownloadManager.defaultName(for: .hlsStream(URL(string: "https://c/path/lecture5.m3u8")!)),
                       "lecture5.mp4")
    }

    private static func aes128CBCEncrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        let capacity = data.count + kCCBlockSizeAES128
        var out = Data(count: capacity)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outPtr in
            data.withUnsafeBytes { dataPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, key.count, ivPtr.baseAddress,
                                dataPtr.baseAddress, data.count,
                                outPtr.baseAddress, capacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw NSError(domain: "aes", code: Int(status)) }
        out.removeSubrange(moved..<out.count)
        return out
    }
}

#endif
