import XCTest
@testable import GoelCore

/// What may be offered as a download uplink. These are Linux-shaped cases: a box
/// running Docker and Tailscale has a dozen interfaces with addresses, and all
/// but one or two are dead ends.
final class AdapterFilterTests: XCTestCase {

    func testContainerAndBridgePlumbingIsHidden() {
        for name in ["docker0", "br-1a2b3c", "veth9f21c0", "virbr0", "cni0",
                     "flannel.1", "cali1234", "kube-ipvs0", "dummy0", "lo"] {
            XCTAssertTrue(AggregationPolicy.isHiddenVirtual(name), "\(name) should be hidden")
        }
    }

    func testRealUplinksAreNotHidden() {
        for name in ["eth0", "enp12s0", "wlp13s0", "wlx782051ac86ae", "bond0", "en0"] {
            XCTAssertFalse(AggregationPolicy.isHiddenVirtual(name), "\(name) should be offered")
            XCTAssertFalse(AggregationPolicy.isVPNInterfaceName(name), "\(name) is not a VPN")
        }
    }

    /// `tailscale0` matches neither `tun*` nor any virtual prefix, so before this
    /// it was offered as an uplink — pinning a download to the tailnet.
    func testPlainlyNamedTunnelsAreTreatedAsVPNs() {
        for name in ["tailscale0", "zt5u4uv63f", "nebula1", "proton0", "nordlynx",
                     "utun3", "wg0", "tun0", "ipsec0", "ppp0"] {
            XCTAssertTrue(AggregationPolicy.isVPNInterfaceName(name), "\(name) should be a VPN")
        }
    }

    private func adapter(_ name: String, type: String = "wired",
                         ipv4: String? = "192.168.0.2", up: Bool = true,
                         expensive: Bool = false) -> NetworkAdapter {
        NetworkAdapter(bsdName: name, displayName: name, type: type,
                       ipv4: ipv4, ipv6: nil, isUp: up, isExpensive: expensive)
    }

    func testUsableAdaptersDropsTunnelsVirtualsAndAddresslessLinks() {
        let all = [adapter("eth0"), adapter("tailscale0", type: "other", ipv4: "100.64.0.1"),
                   adapter("docker0", ipv4: "172.17.0.1"), adapter("eth1", ipv4: nil),
                   adapter("eth2", up: false), adapter("wlan0")]
        let usable = AggregationPolicy.usableAdapters(
            all: all, selectedIds: [], includeExpensive: true, includeVPN: false)
        XCTAssertEqual(usable.map(\.bsdName), ["eth0", "wlan0"])
    }

    // MARK: What a single task may bind to

    private func settings(proxy: String = "none", aggregation: Bool = false,
                          selected: [String] = [], outsideVPN: Bool = false) -> AppSettings {
        var s = AppSettings()
        s.proxyMode = proxy
        s.aggregationEnabled = aggregation
        s.aggregationAdapterIds = selected
        s.aggregationAllowOutsideVPN = outsideVPN
        return s
    }

    /// The saved selection and the aggregation toggle both describe a default the
    /// task is overriding, so neither may narrow what it can pin to.
    func testBindableIgnoresTheSavedSelectionAndTheToggle() {
        let all = [adapter("eth0"), adapter("wlan0", type: "wifi", expensive: true)]
        let bindable = DownloadManager.bindableAdapters(
            settings: settings(aggregation: false, selected: ["eth0"]),
            vpnDefaultRoute: false, all: all)
        XCTAssertEqual(bindable.map(\.bsdName), ["eth0", "wlan0"])
    }

    /// Binding a socket to a NIC bypasses the proxy entirely, so a configured
    /// proxy has to remove the choice rather than merely discourage it.
    func testProxyRemovesEveryBindTarget() {
        let all = [adapter("eth0"), adapter("wlan0")]
        for mode in ["manual", "system"] {
            XCTAssertTrue(DownloadManager.bindableAdapters(
                settings: settings(proxy: mode), vpnDefaultRoute: false, all: all).isEmpty,
                "proxyMode \(mode) must forbid binding")
        }
    }

    func testVPNDefaultRouteRemovesEveryBindTargetUnlessAllowed() {
        let all = [adapter("eth0"), adapter("wlan0")]
        XCTAssertTrue(DownloadManager.bindableAdapters(
            settings: settings(), vpnDefaultRoute: true, all: all).isEmpty)
        XCTAssertEqual(DownloadManager.bindableAdapters(
            settings: settings(outsideVPN: true), vpnDefaultRoute: true, all: all)
            .map(\.bsdName), ["eth0", "wlan0"])
    }

    // MARK: The engine snapshot

    func testAvailableIsPopulatedEvenWhenAggregationIsOff() {
        let all = [adapter("eth0"), adapter("wlan0")]
        let config = DownloadManager.makeAggregationConfig(
            settings: settings(aggregation: false), vpnDefaultRoute: false, adapters: all)
        XCTAssertTrue(config.adapters.isEmpty, "no default fan-out with aggregation off")
        XCTAssertEqual(config.available.map(\.bsdName), ["eth0", "wlan0"])
        XCTAssertFalse(config.isActive)
    }

    func testAggregationOnBindsBothByDefault() {
        let all = [adapter("eth0"), adapter("wlan0")]
        let config = DownloadManager.makeAggregationConfig(
            settings: settings(aggregation: true), vpnDefaultRoute: false, adapters: all)
        XCTAssertEqual(config.adapters.map(\.bsdName), ["eth0", "wlan0"])
        XCTAssertTrue(config.isActive)
    }

    func testProxyLeavesNothingToPinTo() {
        let all = [adapter("eth0"), adapter("wlan0")]
        let config = DownloadManager.makeAggregationConfig(
            settings: settings(proxy: "manual", aggregation: true),
            vpnDefaultRoute: false, adapters: all)
        XCTAssertTrue(config.adapters.isEmpty)
        XCTAssertTrue(config.available.isEmpty)
    }
}
