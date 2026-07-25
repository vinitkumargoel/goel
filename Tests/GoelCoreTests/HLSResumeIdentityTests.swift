import XCTest
@testable import GoelCore

/// Two HLS regressions that both end in a silently wrong download:
///  * a resumed work directory reusing segment files fetched for a *different*
///    rendition (segments are keyed only by playlist position), and
///  * outbound requests dropping the task's captured cookies, `Referer` and
///    custom headers, which the Add Download sheet promises are attached.
final class HLSResumeIdentityTests: XCTestCase {

    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goel-hls-identity-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private func identity(_ url: String, bandwidth: Int, height: Int?) -> String {
        HLSEngine.renditionIdentity(URL(string: url)!, bandwidth: bandwidth, height: height)
    }

    // MARK: Work-directory reuse

    func testResumeKeepsSegmentsOfTheSameRendition() throws {
        let same = identity("https://cdn.example.com/720/index.m3u8", bandwidth: 2_400_000, height: 720)
        try HLSEngine.prepareWorkDir(workDir, identity: same)
        let segment = workDir.appendingPathComponent("seg-000000.bin")
        try Data([1, 2, 3]).write(to: segment)

        try HLSEngine.prepareWorkDir(workDir, identity: same)
        XCTAssertTrue(FileManager.default.fileExists(atPath: segment.path),
                      "resuming the same rendition must still skip segments already on disk")
    }

    func testResumeDiscardsSegmentsFromAnotherRendition() throws {
        try HLSEngine.prepareWorkDir(workDir, identity: identity(
            "https://cdn.example.com/1080/index.m3u8", bandwidth: 6_000_000, height: 1080))
        let segment = workDir.appendingPathComponent("seg-000000.bin")
        try Data([1, 2, 3]).write(to: segment)

        // The user lowered the maximum video height between pause and resume, so
        // the next start selects a different variant. Splicing the two renditions
        // would break the remux (or the video at the join) and still report success.
        try HLSEngine.prepareWorkDir(workDir, identity: identity(
            "https://cdn.example.com/720/index.m3u8", bandwidth: 2_400_000, height: 720))
        XCTAssertFalse(FileManager.default.fileExists(atPath: segment.path),
                       "a 1080p segment must never be reused for a 720p download")
    }

    func testUnstampedWorkDirIsDiscarded() throws {
        // A work directory left by a build that predates the stamp: its rendition
        // is unknowable, so it is not safe to resume into.
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let segment = workDir.appendingPathComponent("seg-000000.bin")
        try Data([1, 2, 3]).write(to: segment)

        try HLSEngine.prepareWorkDir(workDir, identity: identity(
            "https://cdn.example.com/720/index.m3u8", bandwidth: 2_400_000, height: 720))
        XCTAssertFalse(FileManager.default.fileExists(atPath: segment.path))
    }

    // MARK: Rendition identity

    func testIdentityIgnoresARotatingSignedQuery() {
        // Signed CDN URLs re-issue their token on every fetch; folding the query in
        // would make every resume look like a new rendition and discard everything.
        XCTAssertEqual(
            identity("https://cdn.example.com/720/index.m3u8?token=aaa&exp=1", bandwidth: 2_400_000, height: 720),
            identity("https://cdn.example.com/720/index.m3u8?token=bbb&exp=2", bandwidth: 2_400_000, height: 720))
    }

    func testIdentityDistinguishesRenditionsThatShareAPath() {
        XCTAssertNotEqual(identity("https://cdn.example.com/index.m3u8", bandwidth: 6_000_000, height: 1080),
                          identity("https://cdn.example.com/index.m3u8", bandwidth: 2_400_000, height: 720))
    }

    // MARK: Outbound headers

    private func authenticatedTask() -> DownloadTask {
        DownloadTask(source: .hlsStream(URL(string: "https://media.example.com/private/stream.m3u8")!),
                     name: "stream.mp4", saveDirectory: NSTemporaryDirectory(),
                     referer: "https://media.example.com/watch",
                     requestHeaders: ["X-Api-Key": "k"],
                     cookieHeader: "sid=abc",
                     cookieSource: .manual,
                     cookieHost: "media.example.com")
    }

    func testRequestCarriesCookieRefererAndCustomHeaders() {
        let engine = HLSEngine(profile: .high)
        let request = engine.makeRequest(URL(string: "https://media.example.com/private/seg-0.ts")!,
                                         task: authenticatedTask())
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "sid=abc",
                       "a pasted cookie the sheet reports as attached must actually be sent")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://media.example.com/watch")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "k")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "User-Agent"))
    }

    func testCookieIsWithheldFromAThirdPartySegmentHost() {
        // Segments commonly live on a different CDN host; the host-exact scope in
        // `outboundHeaders(for:)` must still hold for HLS.
        let engine = HLSEngine(profile: .high)
        let request = engine.makeRequest(URL(string: "https://cdn.other.net/seg-0.ts")!,
                                         task: authenticatedTask())
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Api-Key"), "k")
    }

    func testByteRangeSegmentStillSendsItsRangeHeader() {
        let engine = HLSEngine(profile: .high)
        let request = engine.makeRequest(URL(string: "https://media.example.com/private/all.ts")!,
                                         task: authenticatedTask(),
                                         range: HLSByteRange(start: 100, length: 50))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=100-149")
    }

    /// Under CMAF single-file packaging the init header is a small slice at the
    /// head of the very resource the fragments occupy. The map's `BYTERANGE` has
    /// to survive parsing *and* the trip into ``HLSEngine/MediaPlan`` — if the
    /// plan drops it, the init fetch becomes an unranged GET of the entire
    /// stream, which then gets concatenated in front of the fragments.
    func testCMAFInitMapKeepsItsRangeFromPlaylistToRequest() throws {
        let playlist = """
        #EXTM3U
        #EXT-X-MAP:URI="stream.mp4",BYTERANGE="1184@0"
        #EXTINF:4.0,
        #EXT-X-BYTERANGE:501760@1184
        stream.mp4
        """
        let base = URL(string: "https://media.example.com/private/index.m3u8")!
        guard case .media(let segs, let map, _, _)? = HLSParser.parse(playlist, baseURL: base),
              let initMap = map else {
            return XCTFail("the CMAF playlist must parse with an init map")
        }
        XCTAssertEqual(initMap.byteRange, HLSByteRange(start: 0, length: 1184))

        // The plan is what `produce()` reads when it fetches the init segment.
        let plan = HLSEngine.MediaPlan(segments: segs, initMap: initMap,
                                       totalDuration: 4.0, bandwidth: 0, identity: "test")
        XCTAssertEqual(plan.initMap?.byteRange, HLSByteRange(start: 0, length: 1184),
                       "the plan must not flatten the map down to a bare URL")

        let engine = HLSEngine(profile: .high)
        let request = engine.makeRequest(initMap.url, task: authenticatedTask(),
                                         range: plan.initMap?.byteRange)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Range"), "bytes=0-1183",
                       "the init fetch must be bounded, not a GET of the whole stream")
    }
}
