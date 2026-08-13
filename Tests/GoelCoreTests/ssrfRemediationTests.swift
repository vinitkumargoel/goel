import XCTest
@testable import GoelCore

final class SSRFRemediationTests: XCTestCase {

    private func url(_ s: String) -> URL { URL(string: s)! }

    /// Bypasses: loopback and metadata spelled without `127.` or `169.254.` — text matching cannot close these.
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

    /// A guard that refuses everything is not a guard: public and private LAN targets must still work.
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
        XCTAssertNil(NetworkGuard.addressClass(ofLiteral: "example.com"))
        XCTAssertNil(NetworkGuard.addressClass(ofLiteral: "0x-mirror.example.com"))
        XCTAssertNil(NetworkGuard.addressClass(ofLiteral: ""))
    }

    /// DNS hides the digits, so resolved addresses are screened too, not just the spelling.
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

    /// A name the screen cannot resolve is exactly the case the screen exists for, so it is refused.
    /// The SOCKS5 case that used to justify fail-open is handled by `resolvedByProxy` below, not by
    /// letting every unscreenable name through.
    func testUnresolvableNameIsRefused() async {
        let target = url("https://\(UUID().uuidString).invalid/file.bin")
        XCTAssertNil(NetworkGuard.resolvedLiterals(of: target.host ?? ""),
                     ".invalid must not resolve")
        let allowed = await NetworkGuard.isAllowedRemoteAddTargetResolvingNames(target)
        XCTAssertFalse(allowed, "a name that cannot be screened must not be allowed through")
    }

    /// The proxy is the trust boundary under SOCKS5 — it, not this host, resolves the name, so an
    /// intranet host or a `.onion` that only it can reach must still be addable.
    func testProxiedTargetIsAllowedThroughTheProxyAwarePath() async {
        let target = url("https://\(UUID().uuidString).invalid/file.bin")
        XCTAssertNil(NetworkGuard.resolvedLiterals(of: target.host ?? ""),
                     ".invalid must not resolve")
        let proxied = await NetworkGuard.isAllowedRemoteAddTargetResolvingNames(
            target, resolvedByProxy: true)
        XCTAssertTrue(proxied, "a name only the proxy can resolve must not be refused for that")

        // Skipping the lookup is not skipping the guard: a spelled-out internal address still loses.
        for internalTarget in ["http://127.0.0.1:8899/api/tasks",
                               "http://169.254.169.254/latest/meta-data/"] {
            let allowed = await NetworkGuard.isAllowedRemoteAddTargetResolvingNames(
                url(internalTarget), resolvedByProxy: true)
            XCTAssertFalse(allowed, "\(internalTarget) must be refused with or without a proxy")
        }
    }

    /// Only a manual SOCKS5 proxy resolves remotely; an HTTP proxy or the system setting must not
    /// buy a free pass out of the screen.
    func testOnlyAManualSOCKS5ProxyCountsAsRemoteDNS() {
        XCTAssertTrue(NetworkGuard.usesRemoteDNS(
            .init(mode: "manual", type: "socks5", host: "10.0.0.9", port: 1080)))
        XCTAssertFalse(NetworkGuard.usesRemoteDNS(
            .init(mode: "manual", type: "http", host: "10.0.0.9", port: 8080)))
        XCTAssertFalse(NetworkGuard.usesRemoteDNS(
            .init(mode: "manual", type: "socks5", host: "", port: 1080)))
        XCTAssertFalse(NetworkGuard.usesRemoteDNS(
            .init(mode: "manual", type: "socks5", host: "10.0.0.9", port: 0)))
        XCTAssertFalse(NetworkGuard.usesRemoteDNS(.init()))
    }

    /// The screen must be stubbable, or every test that names a host also tests the machine's resolver.
    func testTheResolverSeamDecidesTheVerdictAndRestores() async {
        NetworkGuard.hostResolver = { _ in ["127.0.0.1"] }
        defer { NetworkGuard.useSystemHostResolver() }
        var allowed = await NetworkGuard.isAllowedRemoteAddTargetResolvingNames(
            url("https://mirror.example.com/x.bin"))
        XCTAssertFalse(allowed, "the seam's answer, not the name, must decide")

        NetworkGuard.hostResolver = { _ in ["203.0.113.10"] }
        allowed = await NetworkGuard.isAllowedRemoteAddTargetResolvingNames(
            url("https://mirror.example.com/x.bin"))
        XCTAssertTrue(allowed)
    }

    func testResolvingScreenStillRefusesLiterals() async {
        for target in ["http://[::ffff:7f00:1]:8899/api/tasks",
                       "http://[::ffff:a9fe:a9fe]/latest/meta-data/",
                       "file:///etc/passwd"] {
            let allowed = await NetworkGuard.isAllowedRemoteAddTargetResolvingNames(url(target))
            XCTAssertFalse(allowed, "\(target) must be refused without needing DNS")
        }
    }

    /// A document's children are server-chosen: leaving the parent host for loopback or metadata is the pivot.
    func testSubresourceScreenAllowsSameHostAndRefusesAPivot() {
        let parent = url("https://cdn.example.com/video/index.m3u8")
        XCTAssertTrue(NetworkGuard.isAllowedSubresource(url("https://cdn.example.com/v/1.ts"), of: parent))
        XCTAssertTrue(NetworkGuard.isAllowedSubresource(url("https://other.example.com/1.ts"), of: parent))
        XCTAssertFalse(NetworkGuard.isAllowedSubresource(url("http://127.0.0.1:8899/api/tasks"), of: parent))
        XCTAssertFalse(NetworkGuard.isAllowedSubresource(url("http://[::ffff:7f00:1]/x"), of: parent))
        XCTAssertFalse(NetworkGuard.isAllowedSubresource(url("http://169.254.169.254/x"), of: parent))
        XCTAssertFalse(NetworkGuard.isAllowedSubresource(url("file:///etc/passwd"), of: parent))

        let localParent = url("http://127.0.0.1:8080/media/index.m3u8")
        XCTAssertTrue(NetworkGuard.isAllowedSubresource(url("http://127.0.0.1:8080/media/1.ts"),
                                                        of: localParent))
    }

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

    /// `Location` is server-chosen input — following it blind makes every download URL an SSRF primitive.
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

        let localOriginal = url("http://127.0.0.1:8080/a")
        XCTAssertNotNil(RedirectSanitizer.followed(URLRequest(url: url("http://127.0.0.1:8080/b")),
                                                   originalURL: localOriginal))
    }

    /// Any delegate still calling `sanitize` directly leaves the hole open on that path.
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

    /// The spool auto-adds with no confirmation, so a page can make the app fetch a URL unattended.
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

        let magnet = DownloadSource.parse("magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")
        XCTAssertNotNil(magnet)
        XCTAssertNil(magnet?.fetchTargetURL)
    }
}
