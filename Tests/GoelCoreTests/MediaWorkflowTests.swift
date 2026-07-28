import XCTest
import Foundation
@testable import GoelCore

final class MediaWorkflowTests: XCTestCase {

    func testPlaylistURLsAreRecognised() {
        let playlistLike = [
            "https://www.youtube.com/playlist?list=PLabc123",
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLabc123",
            "https://www.youtube.com/@somechannel",
            "https://www.youtube.com/@somechannel/videos",
            "https://www.youtube.com/channel/UC123456/streams",
            "https://www.youtube.com/c/SomeName/playlists",
            "https://soundcloud.com/artist/sets/an-album",
            "https://vimeo.com/album/12345",
        ]
        for url in playlistLike {
            XCTAssertTrue(PlaylistExpander.looksLikePlaylist(url), "should expand: \(url)")
        }
    }

    func testNonPlaylistURLsAreNotOffered() {
        let ordinary = [
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://example.com/big-file.zip",
            "https://example.com/stream/index.m3u8",
            "ftp://example.com/pub/file.iso",
            "magnet:?xt=urn:btih:abc123",
            "not a url at all",
            "",
        ]
        for url in ordinary {
            XCTAssertFalse(PlaylistExpander.looksLikePlaylist(url), "should not expand: \(url)")
        }
    }

    func testEmptyListParameterIsNotAPlaylist() {
        XCTAssertFalse(PlaylistExpander.looksLikePlaylist("https://www.youtube.com/watch?v=abc&list="))
    }

    private let flatPlaylistJSON = """
    {
      "_type": "playlist",
      "id": "PLabc123",
      "title": "Weekly Build Logs",
      "entries": [
        {"_type": "url", "id": "aaa111", "title": "Episode 1", "url": "https://example.com/watch?v=aaa111", "duration": 754},
        {"_type": "url", "id": "bbb222", "title": "Episode 2", "url": "https://example.com/watch?v=bbb222", "duration": 3821.4},
        {"_type": "url", "id": "ccc333", "title": "Episode 3", "url": "https://example.com/watch?v=ccc333"}
      ]
    }
    """

    func testFlatPlaylistParsesTitleAndItems() throws {
        let expansion = try XCTUnwrap(PlaylistExpander.parseFlatPlaylist(flatPlaylistJSON))
        XCTAssertEqual(expansion.title, "Weekly Build Logs")
        XCTAssertFalse(expansion.truncated)
        XCTAssertEqual(expansion.items.count, 3)
        XCTAssertEqual(expansion.items.map(\.id), ["aaa111", "bbb222", "ccc333"])
        XCTAssertEqual(expansion.items.map(\.title), ["Episode 1", "Episode 2", "Episode 3"])
        XCTAssertEqual(expansion.items[0].url, "https://example.com/watch?v=aaa111")
    }

    func testFlatPlaylistNumbersItemsFromOne() throws {
        let expansion = try XCTUnwrap(PlaylistExpander.parseFlatPlaylist(flatPlaylistJSON))
        XCTAssertEqual(expansion.items.map(\.index), [1, 2, 3])
    }

    func testFlatPlaylistDurations() throws {
        let items = try XCTUnwrap(PlaylistExpander.parseFlatPlaylist(flatPlaylistJSON)).items
        XCTAssertEqual(items[0].durationSeconds, 754)
        XCTAssertEqual(items[0].durationText, "12:34")
        XCTAssertEqual(items[1].durationSeconds, 3821)
        XCTAssertEqual(items[1].durationText, "1:03:41")
        XCTAssertNil(items[2].durationSeconds)
        XCTAssertNil(items[2].durationText)
    }

    func testUnavailableEntriesAreSkipped() throws {
        let json = """
        {"_type": "playlist", "title": "Mixed", "entries": [
          {"id": "ok1", "title": "Fine", "url": "https://example.com/1"},
          null,
          {"id": "gone", "title": "[Deleted video]"},
          {"id": "ok2", "title": "Also fine", "url": "https://example.com/2"}
        ]}
        """
        let expansion = try XCTUnwrap(PlaylistExpander.parseFlatPlaylist(json))
        XCTAssertEqual(expansion.items.map(\.id), ["ok1", "ok2"])
        XCTAssertEqual(expansion.items.map(\.index), [1, 2])
    }

    func testWebpageURLPreferredOverFlatURL() throws {
        let json = """
        {"_type": "playlist", "title": "T", "entries": [
          {"id": "x", "title": "X", "url": "https://example.com/short",
           "webpage_url": "https://example.com/watch?v=x"}
        ]}
        """
        let items = try XCTUnwrap(PlaylistExpander.parseFlatPlaylist(json)).items
        XCTAssertEqual(items.first?.url, "https://example.com/watch?v=x")
    }

    func testNestedChannelTabsAreFlattened() throws {
        let json = """
        {"_type": "playlist", "title": "Some Channel", "entries": [
          {"_type": "playlist", "title": "Videos", "entries": [
            {"id": "v1", "title": "One", "url": "https://example.com/v1"},
            {"id": "v2", "title": "Two", "url": "https://example.com/v2"}
          ]},
          {"_type": "playlist", "title": "Shorts", "entries": [
            {"id": "s1", "title": "Short", "url": "https://example.com/s1"}
          ]}
        ]}
        """
        let expansion = try XCTUnwrap(PlaylistExpander.parseFlatPlaylist(json))
        XCTAssertEqual(expansion.title, "Some Channel")
        XCTAssertEqual(expansion.items.map(\.id), ["v1", "v2", "s1"])
        XCTAssertEqual(expansion.items.map(\.index), [1, 2, 3])
    }

    func testSingleVideoJSONIsNotAPlaylist() {
        let json = """
        {"id": "abc", "title": "Just one video", "ext": "mp4",
         "url": "https://example.com/media.mp4"}
        """
        XCTAssertNil(PlaylistExpander.parseFlatPlaylist(json))
    }

    func testGarbageInputIsNotAPlaylist() {
        XCTAssertNil(PlaylistExpander.parseFlatPlaylist(""))
        XCTAssertNil(PlaylistExpander.parseFlatPlaylist("not json"))
        XCTAssertNil(PlaylistExpander.parseFlatPlaylist("[1, 2, 3]"))
    }

    func testOverCapListingIsTruncatedAndSaysSo() throws {
        let entries = (1...(PlaylistExpander.cap + 50)).map {
            ["id": "v\($0)", "title": "Video \($0)", "url": "https://example.com/v\($0)"]
        }
        let payload: [String: Any] = ["_type": "playlist", "title": "Huge", "entries": entries]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let expansion = try XCTUnwrap(PlaylistExpander.parseFlatPlaylist(data))
        XCTAssertEqual(expansion.items.count, PlaylistExpander.cap)
        XCTAssertTrue(expansion.truncated)
    }

    func testPrintListingParsesTabSeparatedRows() {
        let text = """
        aaa111\tEpisode 1\thttps://example.com/watch?v=aaa111\t754
        bbb222\tEpisode 2\thttps://example.com/watch?v=bbb222\t3821.4
        """
        let items = PlaylistExpander.parsePrintListing(text)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].id, "aaa111")
        XCTAssertEqual(items[0].durationSeconds, 754)
        XCTAssertEqual(items[1].durationSeconds, 3821)
        XCTAssertEqual(items.map(\.index), [1, 2])
    }

    func testPrintListingHandlesNAAndShortRows() {
        let text = """
        aaa111\tNA\thttps://example.com/a\tNA
        bbb222\tNo URL here
        \tTitle only\thttps://example.com/c
        ccc333\tFine\tNA
        """
        let items = PlaylistExpander.parsePrintListing(text)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].title, "aaa111", "an NA title falls back to the id")
        XCTAssertNil(items[0].durationSeconds)
        XCTAssertEqual(items[1].id, "https://example.com/c", "a missing id falls back to the URL")
    }

    private let modernTable = """
    [youtube] Extracting URL: https://www.youtube.com/watch?v=dQw4w9WgXcQ
    [info] Available formats for dQw4w9WgXcQ:
    ID  EXT   RESOLUTION FPS CH |   FILESIZE    TBR PROTO | VCODEC        VBR ACODEC      ABR ASR MORE INFO
    --- ----- ---------- --- -- - ---------- ----- ----- - ------------ ----- ---------- ---- --- ---------
    sb2 mhtml 48x27        0    |                   mhtml |                                        storyboard
    139 m4a   audio only      2 |    1.29MiB   49k https | audio only         mp4a.40.5   49k 22k low, m4a_dash
    251 webm  audio only      2 |    3.29MiB  126k https | audio only         opus       126k 48k medium
    18  mp4   640x360     30  2 |    9.78MiB  372k https | avc1.42001E  372k mp4a.40.2     0k 44k 360p
    137 mp4   1920x1080   30    |   50.85MiB 1955k https | avc1.640028 1955k video only         1080p
    303 webm  1920x1080   60    | ~ 78.20MiB 3007k https | vp9         3007k video only         1080p60
    """

    func testModernTableSkipsLogsHeadersAndStoryboards() {
        let formats = MediaFormatTable.parse(modernTable)
        XCTAssertEqual(formats.map(\.id), ["139", "251", "18", "137", "303"],
                       "log lines, the header, the rule and the mhtml storyboard must all be dropped")
    }

    func testModernTableParsesMuxedRow() throws {
        let muxed = try XCTUnwrap(MediaFormatTable.parse(modernTable).first { $0.id == "18" })
        XCTAssertEqual(muxed.ext, "mp4")
        XCTAssertEqual(muxed.resolution, "640x360")
        XCTAssertEqual(muxed.height, 360)
        XCTAssertEqual(muxed.fps, 30)
        XCTAssertEqual(muxed.vcodec, "avc1.42001E")
        XCTAssertEqual(muxed.acodec, "mp4a.40.2")
        XCTAssertTrue(muxed.hasVideo)
        XCTAssertTrue(muxed.hasAudio)
        XCTAssertTrue(muxed.isSelfContained)
        XCTAssertEqual(muxed.note, "360p")
        XCTAssertEqual(muxed.fileSizeBytes, Int64(9.78 * 1_048_576))
        XCTAssertFalse(muxed.isApproximateSize)
    }

    func testModernTableParsesVideoOnlyRow() throws {
        let videoOnly = try XCTUnwrap(MediaFormatTable.parse(modernTable).first { $0.id == "137" })
        XCTAssertTrue(videoOnly.hasVideo)
        XCTAssertFalse(videoOnly.hasAudio)
        XCTAssertTrue(videoOnly.isVideoOnly)
        XCTAssertFalse(videoOnly.isSelfContained, "a video-only track alone would play silently")
        XCTAssertEqual(videoOnly.vcodec, "avc1.640028")
        XCTAssertNil(videoOnly.acodec)
        XCTAssertEqual(videoOnly.height, 1080)
        XCTAssertEqual(videoOnly.note, "1080p")
    }

    func testModernTableParsesAudioOnlyRows() throws {
        let formats = MediaFormatTable.parse(modernTable)
        let m4a = try XCTUnwrap(formats.first { $0.id == "139" })
        XCTAssertTrue(m4a.isAudioOnly)
        XCTAssertFalse(m4a.hasVideo)
        XCTAssertNil(m4a.vcodec)
        XCTAssertEqual(m4a.acodec, "mp4a.40.5")
        XCTAssertEqual(m4a.resolution, "audio only")
        XCTAssertNil(m4a.height)
        XCTAssertNil(m4a.fps, "the CH column must not be mistaken for a frame rate")
        XCTAssertEqual(m4a.note, "low, m4a_dash")

        let opus = try XCTUnwrap(formats.first { $0.id == "251" })
        XCTAssertEqual(opus.acodec, "opus")
        XCTAssertEqual(opus.note, "medium")
    }

    func testApproximateSizeIsFlagged() throws {
        let estimated = try XCTUnwrap(MediaFormatTable.parse(modernTable).first { $0.id == "303" })
        XCTAssertTrue(estimated.isApproximateSize)
        XCTAssertEqual(estimated.fileSizeBytes, Int64(78.20 * 1_048_576))
        XCTAssertEqual(estimated.vcodec, "vp9")
        XCTAssertEqual(estimated.fps, 60)
        XCTAssertEqual(estimated.qualityLabel, "1080p60")
    }

    func testQualityLabelForCommonCases() {
        XCTAssertEqual(MediaFormat(id: "1", ext: "mp4", resolution: "1280x720",
                                   height: 720, fps: 30).qualityLabel, "720p")
        XCTAssertEqual(MediaFormat(id: "2", ext: "m4a", resolution: "audio only",
                                   hasVideo: false).qualityLabel, "audio")
    }

    func testEmptyAndNoiseOnlyInputYieldsNoFormats() {
        XCTAssertTrue(MediaFormatTable.parse("").isEmpty)
        XCTAssertTrue(MediaFormatTable.parse("""
        [youtube] Extracting URL: https://example.com
        ERROR: Video unavailable
        """).isEmpty)
    }

    private let legacyTable = """
    [info] Available formats for BaW_jenozKc:
    format code  extension  resolution note
    249          webm       audio only DASH audio   50k , opus @ 50k, 1.25MiB
    137          mp4        1920x1080  DASH video 2192k , avc1.640028, 30fps, video only, 47.94MiB
    22           mp4        1280x720   hd720 , avc1.64001F, mp4a.40.2@192k (best)
    """

    func testLegacyTableParses() throws {
        let formats = MediaFormatTable.parse(legacyTable)
        XCTAssertEqual(formats.map(\.id), ["249", "137", "22"])

        let audio = try XCTUnwrap(formats.first { $0.id == "249" })
        XCTAssertEqual(audio.ext, "webm")
        XCTAssertTrue(audio.isAudioOnly)
        XCTAssertEqual(audio.fileSizeBytes, Int64(1.25 * 1_048_576))

        let videoOnly = try XCTUnwrap(formats.first { $0.id == "137" })
        XCTAssertTrue(videoOnly.isVideoOnly)
        XCTAssertEqual(videoOnly.height, 1080)

        let best = try XCTUnwrap(formats.first { $0.id == "22" })
        XCTAssertTrue(best.isSelfContained)
        XCTAssertEqual(best.height, 720)
        XCTAssertNil(best.fileSizeBytes, "this layout lists no size for muxed rows")
    }

    func testByteCountUnits() {
        XCTAssertEqual(MediaFormatTable.byteCount("1.29MiB"), Int64(1.29 * 1_048_576))
        XCTAssertEqual(MediaFormatTable.byteCount("~50.85MiB"), Int64(50.85 * 1_048_576))
        XCTAssertEqual(MediaFormatTable.byteCount("900KiB"), 921_600)
        XCTAssertEqual(MediaFormatTable.byteCount("2GiB"), 2_147_483_648)
        XCTAssertEqual(MediaFormatTable.byteCount("12MB"), 12_000_000)
        XCTAssertEqual(MediaFormatTable.byteCount("512B"), 512)
    }

    func testByteCountRejectsNonSizes() {
        XCTAssertNil(MediaFormatTable.byteCount("1955"))
        XCTAssertNil(MediaFormatTable.byteCount("1955k"))
        XCTAssertNil(MediaFormatTable.byteCount("https"))
        XCTAssertNil(MediaFormatTable.byteCount(""))
        XCTAssertNil(MediaFormatTable.byteCount("avc1.640028"))
    }
}
