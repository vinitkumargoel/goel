import XCTest
@testable import GoelCore

final class CookieImportTests: XCTestCase {

    func testParsesPairsInOrder() {
        let pairs = CookieHeader.pairs(in: "sid=abc; csrf=def; theme=dark")
        XCTAssertEqual(pairs.map(\.name), ["sid", "csrf", "theme"])
        XCTAssertEqual(pairs.map(\.value), ["abc", "def", "dark"])
    }

    func testSanitizedNormalisesWhatItCanAndDropsWhatItCannot() {
        let cases: [(raw: String, expected: String?, why: String)] = [
            ("  sid = abc ;  csrf=def  ", "sid=abc; csrf=def", "surrounding whitespace is trimmed"),
            ("sid=abc; cleared=", "sid=abc; cleared=", "an empty value is a real cookie, not junk"),
            ("a=1; b=2; a=3", "a=3; b=2", "a duplicate name keeps the last value at the first position"),
            ("sid=abc; garbage; csrf=def", "sid=abc; csrf=def", "a pair without '=' is dropped"),
            ("", nil, "empty input"),
            ("   ;;;  ", nil, "separators only"),
            ("nothing-here", nil, "no pairs at all"),
            ("sid=a\u{0}b", nil, "NUL in a value"),
            ("sid=a\tb", nil, "control character in a value"),
            ("bad name=abc", nil, "space is not a tchar"),
            ("(bad)=abc", nil, "separators are not tchars"),
            ("=orphan", nil, "empty name"),
            ("sid=café", nil,
             "a value we cannot encode the way the browser did is dropped, not mangled"),
        ]
        for c in cases {
            XCTAssertEqual(CookieHeader.sanitized(c.raw), c.expected, c.why)
        }
    }

    func testRejectsHeaderSplittingValue() {
        // The classic CRLF smuggle: nothing after the injected newline may survive, and neither may the pair carrying it.
        let raw = "sid=abc\r\nX-Evil: 1; csrf=def"
        let cleaned = CookieHeader.sanitized(raw)
        XCTAssertEqual(cleaned, "csrf=def", "the CR/LF-bearing pair is dropped whole")
        XCTAssertFalse(cleaned?.contains("X-Evil") ?? false)
    }

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

    func testNamesExposeNoValues() {
        let names = CookieHeader.names(in: "sid=SECRET; csrf=ALSOSECRET")
        XCTAssertEqual(names, ["sid", "csrf"])
        XCTAssertFalse(names.joined().contains("SECRET"))
    }

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
        let url = URL(string: "https://files.example.com/a.zip")!
        XCTAssertEqual(task(cookie: "sid=abc").outboundHeaders(for: url)["Cookie"], "sid=abc")
    }

    func testNeverSendsCookiesToAnotherHost() {
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
        // Two Cookie headers on one request is a protocol violation, so the captured host-scoped one wins over the header editor's.
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

    func testCookieValueIsNeverEncoded() throws {
        let encoded = try JSONEncoder().encode(
            task(cookie: "sid=SUPERSECRET", cookieHost: "files.example.com"))
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(json.contains("SUPERSECRET"),
                       "a session cookie must never reach the plaintext task store or the JSON export")
        XCTAssertFalse(json.contains("cookieHeader"))
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
        // Guards the hand-written CodingKeys: forget a case and a field silently stops persisting.
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
