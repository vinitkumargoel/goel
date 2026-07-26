import XCTest
@testable import GoelCore

/// Regressions for the confused-deputy paths: every place something *other* than
/// the person at the keyboard chooses a URL this app then fetches.
///
/// There were four, and they shared one root cause — the screen was a check on how
/// an address was *spelled*, applied at exactly one call site.
///
///   * `NetworkGuard` matched `127.` and `::ffff:127.` as text, so
///     `::ffff:7f00:1` (the same address in hex) and `::ffff:a9fe:a9fe` (the
///     cloud-metadata address) sailed through, as did any hostname whose DNS
///     record pointed at either.
///   * `HLSPlaylist.resolve` checked the scheme only, so a playlist body could
///     name `http://127.0.0.1:8899/api/tasks` as a segment and
///     `http://169.254.169.254/…` as its AES key URI.
///   * `RedirectSanitizer` stripped headers on a redirect and then followed it
///     unconditionally, so any http URL that answers `302` reached both.
///   * The browser-extension capture auto-added with no confirmation and no host
///     check at all.
final class SSRFRemediationTests: XCTestCase {

    private func url(_ s: String) -> URL { URL(string: s)! }

    // MARK: Address literals are parsed, not pattern-matched

    /// The demonstrated bypasses. Each of these is loopback or the metadata
    /// address written in a spelling that contains neither `127.` nor `169.254.`,
    /// which is precisely why matching on text could never close them.
    func testEveryLoopbackAndMetadataSpellingIsRefused() {
        let refused = [
            "http://127.0.0.1/x",
            "http://127.1/x",
            "http://2130706433/x",
            "http://0177.0.0.1/x",
            "http://0x7f.1/x",
            "http://[::1]/x",
            "http://[0:0:0:0:0:0:0:1]/x",
            "http://[::ffff:127.0.0.1]/x",
            "http://[::ffff:7f00:1]:8899/api/tasks",
            "http://[0:0:0:0:0:ffff:7f00:1]/x",
            "http://[::127.0.0.1]/x",
            "http://0.0.0.0/x",
            "http://[::]/x",
            "http://169.254.169.254/latest/meta-data/",
            "http://[::ffff:a9fe:a9fe]/latest/meta-data/",
            "http://[fe80::1]/x",
            "http://[fe80::1%25en0]/x",
            "http://[febf::1]/x",
            "http://localhost:8080/x",
            "http://api.localhost/x",
        ]
        for target in refused {
            XCTAssertFalse(NetworkGuard.isAllowedRemoteAddTarget(url(target)),
                           "\(target) must be refused as a remote-initiated add target")
        }
    }

    /// A guard that refuses everything is not a guard. Public addresses, the
    /// private LAN ranges (the whole point of "add the file on my NAS from my
    /// phone"), and a hostname that merely *looks* numeric must all still work.
    func testOrdinaryTargetsAreStillAccepted() {
        let allowed = [
            "https://example.com/x",
            "http://192.168.1.10/feed",
            "http://10.0.0.5/x",
            "http://172.16.4.4/x",
            "http://[2606:4700::1111]/x",
            "http://0x-mirror.example.com/x",
            "http://127-mirror.example.com/x",
            "http://fe80-relay.example.com/x",
            "ftp://ftp.example.com/x",
        ]
        for target in allowed {
            XCTAssertTrue(NetworkGuard.isAllowedRemoteAddTarget(url(target)),
                          "\(target) is an ordinary target and must be accepted")
        }
    }

    /// The classifier judges the address a literal *means*. `::ffff:7f00:1` and
    /// `127.0.0.1` are the same host; a text match sees two unrelated strings.
    func testAddressClassifierReadsEverySpellingOfTheSameAddress() {
        XCTAssertEqual(NetworkGuard.addressClass(ofLiteral: "127.0.0.1"), .loopback)
        XCTAssertEqual(NetworkGuard.addressClass(ofLiteral: "::ffff:7f00:1"), .loopback)
        XCTAssertEqual(NetworkGuard.addressClass(ofLiteral: "[0:0:0:0:0:ffff:7f00:1]"), .loopback)
        XCTAssertEqual(NetworkGuard.addressClass(ofLiteral: "2130706433"), .loopback)
        XCTAssertEqual(NetworkGuard.addressClass(ofLiteral: "0.0.0.0"), .unspecified)
        XCTAssertEqual(NetworkGuard.addressClass(ofLiteral: "::"), .unspecified)
        XCTAssertEqual(NetworkGuard.addressClass(ofLiteral: "169.254.169.254"), .linkLocal)
        XCTAssertEqual(NetworkGuard.addressClass(ofLiteral: "::ffff:a9fe:a9fe"), .linkLocal)
        XCTAssertEqual(NetworkGuard.addressClass(ofLiteral: "fe80::1%en0"), .linkLocal)
        XCTAssertEqual(NetworkGuard.addressClass(ofLiteral: "8.8.8.8"), .other)
        XCTAssertEqual(NetworkGuard.addressClass(ofLiteral: "192.168.0.1"), .other)
        // A name is not a literal, and must be reported as such rather than
        // guessed at — that is what keeps `0x-mirror.example.com` working.
        XCTAssertNil(NetworkGuard.addressClass(ofLiteral: "example.com"))
        XCTAssertNil(NetworkGuard.addressClass(ofLiteral: "0x-mirror.example.com"))
        XCTAssertNil(NetworkGuard.addressClass(ofLiteral: ""))
    }

    /// A hostname pointing at loopback is the same request with the digits hidden
    /// behind DNS, so the resolved addresses are screened too. `localhost` is used
    /// as the fixture because it is the one name guaranteed to resolve to loopback
    /// on every machine without reaching the network.
    func testResolvedAddressesAreScreenedNotJustTheSpelling() async {
        let addresses = NetworkGuard.resolvedLiterals(of: "localhost") ?? []
        XCTAssertFalse(addresses.isEmpty, "localhost must resolve for this test to mean anything")
        XCTAssertTrue(addresses.allSatisfy {
            NetworkGuard.addressClass(ofLiteral: $0) == .loopback
        }, "expected loopback addresses, got \(addresses)")

        let allowed = await NetworkGuard.isAllowedRemoteAddTargetResolvingNames(
            url("http://localhost:8899/api/tasks"))
        XCTAssertFalse(allowed, "a name resolving to loopback must be refused")
    }

    /// A name that cannot be resolved is allowed through deliberately — with a
    /// SOCKS5 proxy the app never resolves locally at all, so refusing every
    /// unresolvable name would refuse every legitimate add made through a proxy.
    func testUnresolvableNameIsNotTreatedAsHostile() async {
        let target = url("https://\(UUID().uuidString).invalid/file.bin")
        XCTAssertNil(NetworkGuard.resolvedLiterals(of: target.host ?? ""),
                     ".invalid must not resolve")
        let allowed = await NetworkGuard.isAllowedRemoteAddTargetResolvingNames(target)
        XCTAssertTrue(allowed, "an unresolvable name must not be refused as internal")
    }

    /// The resolving screen still applies the spelling screen first, so a literal
    /// never depends on a lookup.
    func testResolvingScreenStillRefusesLiterals() async {
        for target in ["http://[::ffff:7f00:1]:8899/api/tasks",
                       "http://[::ffff:a9fe:a9fe]/latest/meta-data/",
                       "file:///etc/passwd"] {
            let allowed = await NetworkGuard.isAllowedRemoteAddTargetResolvingNames(url(target))
            XCTAssertFalse(allowed, "\(target) must be refused without needing DNS")
        }
    }

    // MARK: Sub-resources — playlist children and redirect hops

    /// A document's children are chosen by whoever served the document. Staying on
    /// the same host is always fine (that host was reached deliberately, and every
    /// relative URI resolves there); leaving it for loopback or the metadata range
    /// is the pivot.
    func testSubresourceScreenAllowsSameHostAndRefusesAPivot() {
        let parent = url("https://cdn.example.com/video/index.m3u8")
        XCTAssertTrue(NetworkGuard.isAllowedSubresource(url("https://cdn.example.com/v/1.ts"), of: parent))
        XCTAssertTrue(NetworkGuard.isAllowedSubresource(url("https://other.example.com/1.ts"), of: parent))
        XCTAssertFalse(NetworkGuard.isAllowedSubresource(url("http://127.0.0.1:8899/api/tasks"), of: parent))
        XCTAssertFalse(NetworkGuard.isAllowedSubresource(url("http://[::ffff:7f00:1]/x"), of: parent))
        XCTAssertFalse(NetworkGuard.isAllowedSubresource(url("http://169.254.169.254/x"), of: parent))
        XCTAssertFalse(NetworkGuard.isAllowedSubresource(url("file:///etc/passwd"), of: parent))

        // A genuinely local server keeps working: its own children name itself.
        let localParent = url("http://127.0.0.1:8080/media/index.m3u8")
        XCTAssertTrue(NetworkGuard.isAllowedSubresource(url("http://127.0.0.1:8080/media/1.ts"),
                                                        of: localParent))
    }

    /// The exact playlist from the report: segment URIs pointed at this machine's
    /// own portal and an AES key URI pointed at the cloud-metadata service. A
    /// segment the engine may not fetch rejects the whole playlist rather than
    /// being dropped, because a stream short by one segment is still reported as a
    /// finished download.
    func testPlaylistCannotPointItsSegmentsAtLoopback() {
        let text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXTINF:4.0,
        http://127.0.0.1:8899/api/tasks?token=x
        #EXTINF:4.0,
        http://169.254.169.254/latest/meta-data/
        #EXT-X-ENDLIST
        """
        XCTAssertNil(HLSParser.parse(text, baseURL: url("https://cdn.example.com/video/index.m3u8")),
                     "a playlist whose segments reach into this machine must not parse")
    }

    func testPlaylistCannotPointItsKeyURIAtTheMetadataService() {
        let text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-KEY:METHOD=AES-128,URI="http://169.254.169.254/latest/meta-data/iam/security-credentials/"
        #EXTINF:4.0,
        seg1.ts
        #EXT-X-ENDLIST
        """
        guard case .media(let segments, _, _, _)? =
                HLSParser.parse(text, baseURL: url("https://cdn.example.com/video/index.m3u8")) else {
            return XCTFail("expected a media playlist")
        }
        XCTAssertNil(segments.first?.key?.url,
                     "a key URI aimed at the metadata service must not resolve")
    }

    /// And an ordinary playlist still parses — relative URIs, and an absolute one
    /// on a sibling CDN host.
    func testOrdinaryPlaylistStillParses() {
        let text = """
        #EXTM3U
        #EXT-X-TARGETDURATION:4
        #EXT-X-KEY:METHOD=AES-128,URI="key.bin"
        #EXTINF:4.0,
        seg1.ts
        #EXTINF:4.0,
        https://edge.example.net/video/seg2.ts
        #EXT-X-ENDLIST
        """
        guard case .media(let segments, _, _, _)? =
                HLSParser.parse(text, baseURL: url("https://cdn.example.com/video/index.m3u8")) else {
            return XCTFail("expected a media playlist")
        }
        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments.first?.key?.url?.absoluteString,
                       "https://cdn.example.com/video/key.bin")
    }

    /// A `Location` header is server-chosen input. Following it blind turned every
    /// download URL into an SSRF primitive, no matter how carefully the original
    /// address had been screened.
    func testRedirectToLoopbackOrMetadataIsRefusedNotJustStripped() {
        let original = url("http://attacker.example/redir")
        for hop in ["http://127.0.0.1:8899/api/tasks",
                    "http://[::ffff:7f00:1]:8899/api/tasks",
                    "http://169.254.169.254/latest/meta-data/",
                    "http://localhost:8899/x"] {
            XCTAssertNil(RedirectSanitizer.followed(URLRequest(url: url(hop)), originalURL: original),
                         "a redirect to \(hop) must not be followed")
        }
    }

    /// The hop that is not an attack must still be followed, with its origin-scoped
    /// headers stripped — that is what the sanitizer was already for.
    func testOrdinaryRedirectIsStillFollowedWithSecretsStripped() {
        let original = url("https://files.example.com/a")
        var request = URLRequest(url: url("https://mirror.example.net/b"))
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        request.setValue("goel/1.0", forHTTPHeaderField: "User-Agent")
        let followed = RedirectSanitizer.followed(request, originalURL: original)
        XCTAssertNotNil(followed, "a cross-host hop to a public mirror must still be followed")
        XCTAssertNil(followed?.value(forHTTPHeaderField: "Authorization"),
                     "the bearer token must not travel to another host")
        XCTAssertEqual(followed?.value(forHTTPHeaderField: "User-Agent"), "goel/1.0")

        // A same-host hop on a local server is ordinary, not a pivot.
        let localOriginal = url("http://127.0.0.1:8080/a")
        XCTAssertNotNil(RedirectSanitizer.followed(URLRequest(url: url("http://127.0.0.1:8080/b")),
                                                   originalURL: localOriginal))
    }

    /// Every redirect delegate must go through the refusing entry point; one of them
    /// still calling `sanitize` directly would leave the hole open on that path
    /// only, and each of the three serves a different set of engines.
    func testEveryRedirectDelegateUsesTheRefusingEntryPoint() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in ["Sources/GoelCore/Ports/RedirectSanitizer.swift",
                     "Sources/GoelCore/Ports/NetworkGuard.swift",
                     "Sources/GoelCore/Engine/SegmentedTransfer.swift"] {
            let source = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            guard source.contains("willPerformHTTPRedirection") else { continue }
            XCTAssertTrue(source.contains("RedirectSanitizer.followed(")
                          || source.contains("Self.followed("),
                          "\(path) follows redirects without screening the new host")
        }
    }

    // MARK: The browser-capture spool

    /// The spool auto-adds with no confirmation, so a page that can spool a URL can
    /// make the app fetch it with no user in the loop. `fetchTargetURL` is what the
    /// capture path screens; a magnet has none, which is why it is exempt.
    func testCaptureTargetsExposeTheAddressThatMustBeScreened() {
        let loopback = DownloadSource.parse("http://127.0.0.1:8899/api/tasks")
        XCTAssertNotNil(loopback?.fetchTargetURL)
        XCTAssertFalse(NetworkGuard.isAllowedRemoteAddTarget(loopback!.fetchTargetURL!))

        let metadata = DownloadSource.parse("http://[::ffff:a9fe:a9fe]/latest/meta-data/")
        XCTAssertNotNil(metadata?.fetchTargetURL)
        XCTAssertFalse(NetworkGuard.isAllowedRemoteAddTarget(metadata!.fetchTargetURL!))

        let ordinary = DownloadSource.parse("https://example.com/file.zip")
        XCTAssertNotNil(ordinary?.fetchTargetURL)
        XCTAssertTrue(NetworkGuard.isAllowedRemoteAddTarget(ordinary!.fetchTargetURL!))

        // A magnet reaches its swarm by infohash — there is no host to screen.
        let magnet = DownloadSource.parse("magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")
        XCTAssertNotNil(magnet)
        XCTAssertNil(magnet?.fetchTargetURL)
    }
}
