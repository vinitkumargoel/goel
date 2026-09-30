import XCTest
@testable import GoelCore

/// integration#5: a Mac app has no environment, so the portal's extra Host names need a real setting.
final class RemoteAllowedHostNamesTests: XCTestCase {

    func testPastedURLsAndPortsAreNormalisedToBareNames() {
        let raw = [" https://Goel.Home:8899/ ", "mymac.tailnet.ts.net.", "*.Corp.Example",
                   "user@nas.lan:443", "", "   ", "goel.home", "[::1]", "a:b:c", "bad name.example",
                   "*.", ".evil"]
        XCTAssertEqual(AppSettings.normalizedHostNames(raw),
                       ["goel.home", "mymac.tailnet.ts.net", "*.corp.example", "nas.lan"])
    }

    func testTheListIsCapped() {
        let many = (0..<100).map { "h\($0).example" }
        XCTAssertEqual(AppSettings.normalizedHostNames(many).count, AppSettings.maxAllowedHostNames)
    }

    func testValidatedNormalisesTheSetting() {
        var s = AppSettings()
        s.remoteAllowedHostNames = ["HTTP://Goel.Home/"]
        XCTAssertEqual(s.validated().remoteAllowedHostNames, ["goel.home"])
    }

    func testOldSettingsJSONWithoutTheKeyStillDecodes() throws {
        var json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings())) as? [String: Any])
        json.removeValue(forKey: "remoteAllowedHostNames")
        let data = try JSONSerialization.data(withJSONObject: json)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: data).remoteAllowedHostNames, [])
    }

    func testRoundTrips() throws {
        var s = AppSettings()
        s.remoteAllowedHostNames = ["goel.home"]
        let back = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.remoteAllowedHostNames, ["goel.home"])
    }

    func testSettingUnionsWithTheEnvironmentAndFeedsTheHostCheck() {
        var s = AppSettings()
        s.remoteAllowedHostNames = ["goel.home", "shared.example"]
        let hosts = RemotePortalSecurity.allowedHosts(settings: s, environment: ["shared.example", "env.example"])
        XCTAssertEqual(hosts, ["shared.example", "env.example", "goel.home"])

        let security = RemotePortalSecurity(allowedHosts: hosts)
        XCTAssertTrue(RemoteHostPolicy.allows(hostHeader: "goel.home:8899", client: "192.168.1.5",
                                              security: security))
        XCTAssertFalse(RemoteHostPolicy.allows(hostHeader: "evil.example", client: "192.168.1.5",
                                               security: security))
    }

    func testSettingsInitCarriesTheSetting() {
        var s = AppSettings()
        s.remoteAllowedHostNames = ["mymac.tailnet.ts.net"]
        XCTAssertTrue(RemotePortalSecurity(settings: s).allowedHosts.contains("mymac.tailnet.ts.net"))
    }

    func testChangingTheListRestartsThePortal() {
        var next = AppSettings()
        next.remoteAllowedHostNames = ["goel.home"]
        XCTAssertTrue(RemoteAccessPolicy.needsRestart(previous: AppSettings(), next: next))
    }

    func testManagedPolicyForcesTheList() {
        let policy = ManagedPolicy(forced: [.remoteAllowedHostNames: .stringList(["HTTPS://Goel.Corp:443"])])
        XCTAssertEqual(policy.apply(to: AppSettings()).remoteAllowedHostNames, ["goel.corp"])
    }
}
