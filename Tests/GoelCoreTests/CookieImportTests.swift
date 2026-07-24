import XCTest
@testable import GoelCore

/// Tests for browser cookie import: the ``CookieHeader`` parser/sanitiser, the
/// host scoping that decides whether a captured session may ride on a request,
/// and the guarantee that a cookie never reaches persisted JSON.
///
/// All pure — no network, no browser, no engine. The live capture path is the
/// extension + native-messaging host, which these rules sit underneath.
final class CookieImportTests: XCTestCase {

    // MARK: Parsing

    func testParsesPairsInOrder() {
        let pairs = CookieHeader.pairs(in: "sid=abc; csrf=def; theme=dark")
        XCTAssertEqual(pairs.map(\.name), ["sid", "csrf", "theme"])
        XCTAssertEqual(pairs.map(\.value), ["abc", "def", "dark"])
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(CookieHeader.sanitized("  sid = abc ;  csrf=def  "), "sid=abc; csrf=def")
    }

    func testKeepsEmptyValuedCookie() {
        // Servers really do issue `name=` to clear a slot; dropping it changes
        // the request the browser would have made.
        XCTAssertEqual(CookieHeader.sanitized("sid=abc; cleared="), "sid=abc; cleared=")
    }

    func testDuplicateNameKeepsLastValueAtFirstPosition() {
        XCTAssertEqual(CookieHeader.sanitized("a=1; b=2; a=3"), "a=3; b=2")
    }

    func testDropsPairsWithoutEquals() {
        XCTAssertEqual(CookieHeader.sanitized("sid=abc; garbage; csrf=def"), "sid=abc; csrf=def")
    }

    func testEmptyAndJunkInputYieldNil() {
        XCTAssertNil(CookieHeader.sanitized(""))
        XCTAssertNil(CookieHeader.sanitized("   ;;;  "))
        XCTAssertNil(CookieHeader.sanitized("nothing-here"))
    }

    // MARK: Injection resistance

    func testRejectsHeaderSplittingValue() {
        // The classic CRLF smuggle: everything after the injected newline must
        // not survive, and neither must the pair carrying it.
        let raw = "sid=abc\r\nX-Evil: 1; csrf=def"
        let cleaned = CookieHeader.sanitized(raw)
        XCTAssertEqual(cleaned, "csrf=def", "the CR/LF-bearing pair is dropped whole")
        XCTAssertFalse(cleaned?.contains("X-Evil") ?? false)
    }

    func testRejectsNulAndControlCharacters() {
        XCTAssertNil(CookieHeader.sanitized("sid=a\u{0}b"))
        XCTAssertNil(CookieHeader.sanitized("sid=a\tb"))
    }

    func testRejectsInvalidNameCharacters() {
        XCTAssertNil(CookieHeader.sanitized("bad name=abc"), "space is not a tchar")
        XCTAssertNil(CookieHeader.sanitized("(bad)=abc"), "separators are not tchars")
        XCTAssertNil(CookieHeader.sanitized("=orphan"), "empty name")
    }

    func testRejectsNonASCIIValue() {
        XCTAssertNil(CookieHeader.sanitized("sid=café"),
                     "a value we cannot encode the way the browser did is dropped, not mangled")
    }

    // MARK: Size caps

    func testCapsPairCount() {
        let raw = (0..<(CookieHeader.maxPairs + 40)).map { "c\($0)=v" }.joined(separator: "; ")
        XCTAssertEqual(CookieHeader.count(in: raw), CookieHeader.maxPairs)
    }

    func testCapsTotalLength() {
        // 200 pairs of ~52 bytes each = ~10 KB raw, over the 8 KiB budget.
        let raw = (0..<200).map { "cookie\($0)=\(String(repeating: "x", count: 40))" }
            .joined(separator: "; ")
        let cleaned = CookieHeader.sanitized(raw)
        XCTAssertNotNil(cleaned)
        XCTAssertLessThanOrEqual(cleaned!.utf8.count, CookieHeader.maxLength)
        XCTAssertTrue(cleaned!.hasPrefix("cookie0="), "the cap drops the tail, keeping the earliest pairs")
    }

    // MARK: Names-only surface

    func testNamesExposeNoValues() {
        let names = CookieHeader.names(in: "sid=SECRET; csrf=ALSOSECRET")
        XCTAssertEqual(names, ["sid", "csrf"])
        XCTAssertFalse(names.joined().contains("SECRET"))
    }

    // MARK: Host scoping

    func testScopeIsLowercasedHost() {
        XCTAssertEqual(CookieHeader.scope(for: URL(string: "https://Files.Example.com/a.zip")!),
                       "files.example.com")
    }

    func testMatchesIsHostExactAndCaseInsensitive() {
        let url = URL(string: "https://files.example.com/a.zip")!
        XCTAssertTrue(CookieHeader.matches(cookieHost: "FILES.example.com", url: url))
        XCTAssertFalse(CookieHeader.matches(cookieHost: "example.com", url: url),
                       "a parent domain is a different trust boundary")
        XCTAssertFalse(CookieHeader.matches(cookieHost: "evil-files.example.com", url: url))
        XCTAssertFalse(CookieHeader.matches(cookieHost: nil, url: url))
        XCTAssertFalse(CookieHeader.matches(cookieHost: "   ", url: url))
    }

    // MARK: Attachment to a request

    private func task(cookie: String?, cookieHost: String? = nil,
                      headers: [String: String]? = nil,
                      url: String = "https://files.example.com/a.zip") -> DownloadTask {
        DownloadTask(source: .url(URL(string: url)!),
                     name: "a.zip", saveDirectory: "/tmp",
                     requestHeaders: headers,
                     cookieHeader: cookie,
                     cookieSource: cookie == nil ? CookieSource.none : .browser,
                     cookieHost: cookieHost)
    }

    func testAttachesCookieToMatchingHost() {
        let url = URL(string: "https://files.example.com/a.zip")!
        let headers = task(cookie: "sid=abc", cookieHost: "files.example.com").outboundHeaders(for: url)
        XCTAssertEqual(headers["Cookie"], "sid=abc")
    }

    func testFallsBackToTheTaskOwnHostWhenNoScopeStored() {
        // The manual-paste case: the user pasted cookies *for this download*.
        let url = URL(string: "https://files.example.com/a.zip")!
        XCTAssertEqual(task(cookie: "sid=abc").outboundHeaders(for: url)["Cookie"], "sid=abc")
    }

    func testNeverSendsCookiesToAnotherHost() {
        // The mirror case — the reason the scope is stored at all.
        let mirror = URL(string: "https://mirror.other.net/a.zip")!
        let headers = task(cookie: "sid=abc", cookieHost: "files.example.com").outboundHeaders(for: mirror)
        XCTAssertNil(headers["Cookie"])
        XCTAssertFalse(task(cookie: "sid=abc", cookieHost: "files.example.com").sendsCookies(to: mirror))
    }

    func testNoCookieLeavesCustomHeadersUntouched() {
        let url = URL(string: "https://files.example.com/a.zip")!
        let headers = task(cookie: nil, headers: ["X-Api-Key": "k"]).outboundHeaders(for: url)
        XCTAssertEqual(headers, ["X-Api-Key": "k"])
    }

    func testCapturedCookieReplacesAUserTypedOne() {
        // Two Cookie headers on one request is a protocol violation; the captured
        // (host-scoped) one wins over whatever was typed into the header editor.
        let url = URL(string: "https://files.example.com/a.zip")!
        let headers = task(cookie: "sid=real", cookieHost: "files.example.com",
                           headers: ["cookie": "sid=typed", "X-Api-Key": "k"])
            .outboundHeaders(for: url)
        XCTAssertEqual(headers["Cookie"], "sid=real")
        XCTAssertNil(headers["cookie"])
        XCTAssertEqual(headers["X-Api-Key"], "k")
    }

    func testMagnetTaskNeverSendsCookies() {
        var magnet = DownloadTask(source: .magnet("magnet:?xt=urn:btih:\(String(repeating: "a", count: 40))"),
                                  name: "t", saveDirectory: "/tmp")
        magnet.cookieHeader = "sid=abc"
        XCTAssertNil(magnet.sourceHost)
        XCTAssertFalse(magnet.sendsCookies(to: URL(string: "https://files.example.com/a.zip")!))
    }

    // MARK: Persistence exclusion — the storage guarantee

    func testCookieValueIsNeverEncoded() throws {
        let encoded = try JSONEncoder().encode(
            task(cookie: "sid=SUPERSECRET", cookieHost: "files.example.com"))
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(json.contains("SUPERSECRET"),
                       "a session cookie must never reach the plaintext task store or the JSON export")
        XCTAssertFalse(json.contains("cookieHeader"))
        // Provenance is not a secret and must survive, so the UI can explain the
        // empty jar after a relaunch.
        XCTAssertTrue(json.contains("cookieHost"))
        XCTAssertTrue(json.contains("browser"))
    }

    func testDecodedTaskComesBackCookieLessButKeepsProvenance() throws {
        let original = task(cookie: "sid=SUPERSECRET", cookieHost: "files.example.com")
        let restored = try JSONDecoder().decode(
            DownloadTask.self, from: JSONEncoder().encode(original))
        XCTAssertNil(restored.cookieHeader)
        XCTAssertEqual(restored.cookieSource, .browser)
        XCTAssertEqual(restored.cookieHost, "files.example.com")
        XCTAssertFalse(restored.sendsCookies(to: URL(string: "https://files.example.com/a.zip")!))
    }

    func testUnrelatedFieldsStillRoundTrip() throws {
        // The hand-written CodingKeys is the risk this guards: forget a case and a
        // field silently stops persisting.
        var original = task(cookie: nil, headers: ["X-Api-Key": "k"])
        original.referer = "https://example.com/page"
        original.tags = ["work"]
        original.note = "note"
        original.mirrors = ["https://mirror.example.com/a.zip"]
        original.speedLimitBytesPerSec = 1024
        original.retryAttempt = 2
        original.initialSkipFileIDs = [3]
        original.expectedChecksum = Checksum(algorithm: .sha256, value: String(repeating: "a", count: 64))
        let restored = try JSONDecoder().decode(
            DownloadTask.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored, original)
    }
}
