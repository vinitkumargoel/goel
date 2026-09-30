import XCTest
import GoelCore
@testable import GoelApp

final class BrowserSpoolTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goel-spool-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func jsonFiles(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
            .filter { $0.hasSuffix(".json") }
    }

    func testReadingDoesNotDeleteUntilAcknowledged() throws {
        try BrowserSpool.enqueue(BrowserCapture(locator: "https://e.test/a.zip"), into: dir)
        let first = BrowserSpool.pendingCaptures(in: dir)
        XCTAssertEqual(first.map(\.capture.locator), ["https://e.test/a.zip"])
        // The app died before adding it: the next drain still finds it.
        XCTAssertEqual(BrowserSpool.pendingCaptures(in: dir).count, 1)
        BrowserSpool.acknowledge(first[0].file)
        XCTAssertTrue(BrowserSpool.pendingCaptures(in: dir).isEmpty)
    }

    func testUnparseableFilesAreParkedNotDropped() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("broken.json"))
        XCTAssertTrue(BrowserSpool.pendingCaptures(in: dir).isEmpty)
        XCTAssertTrue(jsonFiles(dir).isEmpty)
        XCTAssertEqual(jsonFiles(BrowserSpool.rejectedDirectory(in: dir)), ["broken.json"])
    }

    func testAuthorizationTravelsButExpiresLikeTheCookie() throws {
        try BrowserSpool.enqueue(BrowserCapture(locator: "https://e.test/a.zip",
                                                authorization: "Basic dTpw"), into: dir)
        XCTAssertEqual(BrowserSpool.pendingCaptures(in: dir).first?.capture.authorization, "Basic dTpw")
        let later = Date().addingTimeInterval(BrowserSpool.cookieMaxAge + 60)
        let stale = BrowserSpool.pendingCaptures(in: dir, now: later).first
        XCTAssertEqual(stale?.capture.locator, "https://e.test/a.zip", "the URL is kept")
        XCTAssertNil(stale?.capture.authorization, "the credential is not")
    }
}

final class BrowserCaptureScreenTests: XCTestCase {

    private func verdict(_ raw: String, portal: Int? = 8899,
                         resolve: @escaping NetworkGuard.HostResolver = { _ in ["93.184.216.34"] }) async
        -> BrowserCaptureScreen.Verdict {
        await BrowserCaptureScreen.verdict(URL(string: raw)!, portalPort: portal,
                                           resolvedByProxy: false, resolve: resolve)
    }

    func testPrivateLANTargetsAreAllowedFromTheExtension() async {
        let a = await verdict("http://192.168.1.20/share/movie.mkv")
        let b = await verdict("http://10.0.0.5:5000/f.iso")
        let c = await verdict("http://nas.local/f.iso", resolve: { _ in ["192.168.1.20"] })
        XCTAssertEqual(a, .allowed)
        XCTAssertEqual(b, .allowed)
        XCTAssertEqual(c, .allowed)
    }

    func testCloudMetadataAndLinkLocalStayRefused() async {
        let meta = await verdict("http://169.254.169.254/latest/meta-data/")
        let v6 = await verdict("http://[fd00:ec2::254]/latest/")
        let rebound = await verdict("http://evil.test/", resolve: { _ in ["169.254.169.254"] })
        XCTAssertNotEqual(meta, .allowed)
        XCTAssertNotEqual(v6, .allowed)
        XCTAssertNotEqual(rebound, .allowed)
    }

    func testGoelsOwnPortalOnLoopbackIsRefused() async {
        let direct = await verdict("http://127.0.0.1:8899/api/tasks")
        let named = await verdict("http://localtest.me:8899/api/tasks", resolve: { _ in ["127.0.0.1"] })
        let localhost = await verdict("http://localhost:8899/")
        let otherPort = await verdict("http://127.0.0.1:3000/build.zip")
        XCTAssertEqual(direct, .refused("portal"))
        XCTAssertEqual(named, .refused("portal"))
        XCTAssertEqual(localhost, .refused("portal"))
        XCTAssertEqual(otherPort, .allowed)
    }

    func testTheHostProcessScreensSpellingOnly() {
        XCTAssertNotEqual(BrowserCaptureScreen.spellingVerdict(
            URL(string: "http://169.254.169.254/")!, portalPort: nil), .allowed)
        XCTAssertEqual(BrowserCaptureScreen.spellingVerdict(
            URL(string: "http://192.168.1.2/f")!, portalPort: nil), .allowed)
    }

    func testMappedIPv4IsJudgedAsIPv4() {
        XCTAssertEqual(BrowserCaptureScreen.classify("::ffff:169.254.169.254"), .linkLocal)
        XCTAssertEqual(BrowserCaptureScreen.classify("::1"), .loopback)
        XCTAssertNil(BrowserCaptureScreen.classify("192.168.0.1"))
    }

    func testAnUnresolvableNameFailsClosed() async {
        let result = await verdict("http://nowhere.invalid/f", resolve: { _ in nil })
        XCTAssertNotEqual(result, .allowed)
    }
}
