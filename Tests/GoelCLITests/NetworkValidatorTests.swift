import XCTest
@testable import GoelCLI

/// The CLI validates interface names locally so a typo is caught before it is
/// written into `/etc/goel/config` (where the daemon would refuse to boot on it)
/// or sent to the API. These mirror `NetworkSelection` in GoelCore — the two
/// grammars are duplicated on purpose, so a test that they agree is the only
/// thing keeping them from drifting.
final class NetworkValidatorTests: XCTestCase {

    func testInterfaceNamesFollowIFNAMSIZ() {
        XCTAssertTrue(Validators.isInterfaceName("wlp13s0"))
        XCTAssertTrue(Validators.isInterfaceName("wlx782051ac86ae"))     // 15 characters
        XCTAssertTrue(Validators.isInterfaceName("br-1a2b"))
        XCTAssertFalse(Validators.isInterfaceName(""))
        XCTAssertFalse(Validators.isInterfaceName(String(repeating: "a", count: 16)))
        XCTAssertFalse(Validators.isInterfaceName("eth 0"))
        XCTAssertFalse(Validators.isInterfaceName("../etc"))
        XCTAssertFalse(Validators.isInterfaceName("eth0\u{0}"))
    }

    func testInterfaceListAcceptsEmptyMeaningEveryEligibleOne() {
        XCTAssertNil(Validators.interfaceList(""))
        XCTAssertNil(Validators.interfaceList("eth0"))
        XCTAssertNil(Validators.interfaceList("eth0,wlan0"))
        XCTAssertNil(Validators.interfaceList(" eth0 , wlan0 "))
        XCTAssertNotNil(Validators.interfaceList("eth0,bad iface"))
    }

    func testStreamsPerAdapterIsBounded() {
        XCTAssertNil(Validators.streamsPerAdapter("1"))
        XCTAssertNil(Validators.streamsPerAdapter("8"))
        for bad in ["0", "9", "-1", "", "two", "2.5"] {
            XCTAssertNotNil(Validators.streamsPerAdapter(bad), "‘\(bad)’ should be refused")
        }
    }

    func testNetworkSpecGrammar() {
        for good in ["", "auto", "AUTO", "single:eth0", "aggregate", "aggregate:eth0,wlan0"] {
            XCTAssertNil(Validators.networkSpec(good), "‘\(good)’ should be accepted")
        }
        for bad in ["single:", "single", "split:eth0", "aggregate:eth0,bad iface",
                    "single:../../etc"] {
            XCTAssertNotNil(Validators.networkSpec(bad), "‘\(bad)’ should be refused")
        }
    }

    /// The three new keys have to be reachable by name, or `goel config set
    /// aggregation on` reports "unknown setting" and the feature is unusable.
    func testTheAggregationSettingsAreRegistered() throws {
        for key in ["aggregation", "aggregation-adapters", "aggregation-streams"] {
            let entry = try XCTUnwrap(setting(named: key), "‘\(key)’ is not registered")
            XCTAssertTrue(entry.env.hasPrefix("GOEL_AGGREGATION"))
            XCTAssertFalse(entry.secret, "an interface list is not a secret")
        }
        XCTAssertEqual(setting(named: "aggregation")?.env, "GOEL_AGGREGATION")
        XCTAssertEqual(setting(named: "aggregation-adapters")?.env, "GOEL_AGGREGATION_ADAPTERS")
        XCTAssertEqual(setting(named: "aggregation-streams")?.env, "GOEL_AGGREGATION_STREAMS")
    }

    func testAggregationSettingsValidateWhatTheDaemonWillRead() throws {
        let toggle = try XCTUnwrap(setting(named: "aggregation"))
        XCTAssertNil(toggle.validate("true"))
        XCTAssertNotNil(toggle.validate("maybe"))

        let list = try XCTUnwrap(setting(named: "aggregation-adapters"))
        XCTAssertNil(list.validate("eth0,wlan0"))
        XCTAssertNotNil(list.validate("eth0;wlan0"))

        let streams = try XCTUnwrap(setting(named: "aggregation-streams"))
        XCTAssertNil(streams.validate("4"))
        XCTAssertNotNil(streams.validate("40"))
    }
}
