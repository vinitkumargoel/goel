import XCTest
@testable import GoelCore

final class NetworkGuardPrivateRangeTests: XCTestCase {

    private func url(_ s: String) -> URL { URL(string: s)! }

    override func tearDown() {
        NetworkGuard.useSystemHostResolver()
        NetworkGuard.privateTargetAllowlist = []
        super.tearDown()
    }

    func testAddressClassificationTable() {
        let table: [(String, NetworkGuard.AddressClass?)] = [
            ("10.0.0.5", .privateNetwork),
            ("10.255.255.255", .privateNetwork),
            ("172.16.4.4", .privateNetwork),
            ("172.31.255.1", .privateNetwork),
            ("172.32.0.1", .other),
            ("192.168.1.10", .privateNetwork),
            ("100.64.0.1", .privateNetwork),
            ("100.127.255.254", .privateNetwork),
            ("100.128.0.1", .other),
            ("192.0.0.8", .privateNetwork),
            ("198.18.0.1", .privateNetwork),
            ("198.19.255.1", .privateNetwork),
            ("198.20.0.1", .other),
            ("169.254.169.254", .linkLocal),
            ("127.0.0.1", .loopback),
            ("0.0.0.0", .unspecified),
            ("8.8.8.8", .other),
            ("fd00:ec2::254", .privateNetwork),
            ("fc00::1", .privateNetwork),
            ("fe80::1", .linkLocal),
            ("::ffff:10.0.0.1", .privateNetwork),
            ("64:ff9b::7f00:1", .loopback),
            ("64:ff9b::a9fe:a9fe", .linkLocal),
            ("64:ff9b::c0a8:101", .privateNetwork),
            ("64:ff9b::808:808", .other),
            ("64:ff9b:1::1", .privateNetwork),
            ("2002:7f00:1::", .loopback),
            ("2002:c0a8:101::1", .privateNetwork),
            ("2002:808:808::1", .other),
            ("2606:4700::1111", .other),
            ("example.com", nil),
        ]
        for (literal, expected) in table {
            XCTAssertEqual(NetworkGuard.addressClass(ofLiteral: literal), expected, literal)
        }
    }

    func testRemoteAddRefusesPrivateRangesButAllowlistUnlocksThem() {
        for target in ["http://192.168.1.10/f", "http://10.0.0.5/f", "http://[fd00::1]/f",
                       "http://100.64.1.1/f", "http://[64:ff9b::7f00:1]/f"] {
            XCTAssertFalse(NetworkGuard.isAllowedRemoteAddTarget(url(target)), target)
        }
        NetworkGuard.privateTargetAllowlist = ["192.168.1.0/24"]
        XCTAssertTrue(NetworkGuard.isAllowedRemoteAddTarget(url("http://192.168.1.10/f")))
        XCTAssertFalse(NetworkGuard.isAllowedRemoteAddTarget(url("http://10.0.0.5/f")))
        NetworkGuard.privateTargetAllowlist = ["127.0.0.1", "0.0.0.0/0"]
        XCTAssertFalse(NetworkGuard.isAllowedRemoteAddTarget(url("http://127.0.0.1/f")),
                       "the allowlist must never unlock loopback")
    }

    func testResolvingScreenRefusesANameThatResolvesPrivate() async {
        NetworkGuard.hostResolver = { _ in ["192.168.0.1"] }
        let refused = await NetworkGuard.isAllowedRemoteAddTargetResolvingNames(
            url("https://router.example.com/admin"))
        XCTAssertFalse(refused)
        NetworkGuard.privateTargetAllowlist = ["router.example.com"]
        let allowed = await NetworkGuard.isAllowedRemoteAddTargetResolvingNames(
            url("https://router.example.com/admin"))
        XCTAssertTrue(allowed)
    }

    func testScreenSplitsSourcesAndPassesMagnets() async {
        NetworkGuard.hostResolver = { host in host == "public.example" ? ["203.0.113.5"] : ["10.1.1.1"] }
        let sources = [
            DownloadSource.parse("https://public.example/a.bin")!,
            DownloadSource.parse("https://intranet.example/b.bin")!,
            DownloadSource.parse("magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567")!,
        ]
        let result = await NetworkGuard.screen(sources: sources)
        XCTAssertEqual(result.allowed.count, 2)
        XCTAssertEqual(result.refused.map(\.locator), ["https://intranet.example/b.bin"])
    }

    func testRedirectFromPublicToPrivateLiteralIsRefused() {
        let pub = url("https://files.example.com/a")
        XCTAssertFalse(NetworkGuard.isAllowedSubresource(url("http://192.168.1.1/admin"), of: pub))
        XCTAssertNil(RedirectSanitizer.followed(URLRequest(url: url("http://10.0.0.1/x")), originalURL: pub))
        // LAN → LAN is an ordinary NAS redirect.
        XCTAssertTrue(NetworkGuard.isAllowedSubresource(url("http://192.168.1.5:5000/f"),
                                                        of: url("http://192.168.1.5/f")))
        XCTAssertTrue(NetworkGuard.isAllowedSubresource(url("http://192.168.1.6/f"),
                                                        of: url("http://nas.local/f")))
        XCTAssertTrue(NetworkGuard.isAllowedSubresource(url("http://10.0.0.2/f"),
                                                        of: url("http://nas/f")))
    }

    func testResolvingRedirectScreenSeesThroughDNS() async {
        NetworkGuard.hostResolver = { host in
            switch host {
            case "127.0.0.1.nip.io": return ["127.0.0.1"]
            case "lan.example.com": return ["192.168.1.9"]
            case "corp-files.example.com": return ["10.2.3.4"]
            case "public.example.com": return ["203.0.113.7"]
            default: return nil
            }
        }
        let pub = url("https://public.example.com/a")
        var ok = await NetworkGuard.isAllowedRedirectResolvingNames(url("http://127.0.0.1.nip.io/x"), from: pub)
        XCTAssertFalse(ok, "a name resolving to loopback must not be followed")
        ok = await NetworkGuard.isAllowedRedirectResolvingNames(url("http://lan.example.com/x"), from: pub)
        XCTAssertFalse(ok, "public → private must not be followed")
        ok = await NetworkGuard.isAllowedRedirectResolvingNames(
            url("http://lan.example.com/x"), from: url("https://corp-files.example.com/a"))
        XCTAssertTrue(ok, "private → private (corporate mirror) is fine")
        ok = await NetworkGuard.isAllowedRedirectResolvingNames(url("https://mirror.unknown/x"), from: pub)
        XCTAssertTrue(ok, "an unresolvable hop is left to the proxy/fetch, not refused")
    }

    func testFetchCheckedRefusesLinkLocalWithAReason() async {
        do {
            _ = try await NetworkGuard.fetchChecked(url: url("http://169.254.169.254/latest"),
                                                    proxy: .init(mode: "none"), userAgent: "t")
            XCTFail("expected a refusal")
        } catch let error as NetworkGuard.FetchError {
            XCTAssertEqual(error, .refusedTarget)
            XCTAssertFalse(error.description.isEmpty)
        } catch {
            XCTFail("unexpected \(error)")
        }
        let legacy = await NetworkGuard.fetch(url: url("http://169.254.169.254/latest"),
                                              proxy: .init(mode: "none"), userAgent: "t")
        XCTAssertNil(legacy)
    }

    func testFetchErrorTextCarriesTheStatus() {
        XCTAssertTrue(NetworkGuard.FetchError.httpStatus(404).description.contains("404"))
        XCTAssertTrue(NetworkGuard.FetchError.httpStatus(302).description.contains("302"))
        XCTAssertEqual(NetworkGuard.FetchError.transport("TLS failed").description, "TLS failed")
    }

    func testFetchCheckedTransportErrorKeepsTheUnderlyingText() async {
        let port = LoopbackPort.reserve()   // nothing listens there
        do {
            _ = try await NetworkGuard.fetchChecked(url: url("http://127.0.0.1:\(port)/x"),
                                                    proxy: .init(mode: "none"), userAgent: "t",
                                                    timeout: 5)
            XCTFail("expected a transport error")
        } catch let NetworkGuard.FetchError.transport(reason) {
            XCTAssertFalse(reason.isEmpty)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
