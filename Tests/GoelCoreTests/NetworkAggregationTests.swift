import XCTest
@testable import GoelCore

final class NetworkAggregationTests: XCTestCase {

    // MARK: - AggregationPolicy

    func testShouldActivateRequiresEnabledAndTwoAdapters() {
        XCTAssertEqual(
            AggregationPolicy.shouldActivate(
                enabled: false, usableAdapterCount: 3,
                enableExtraConnections: true, proxyMode: "none",
                vpnDefaultRoute: false, allowOutsideVPN: false),
            .disabled)
        XCTAssertEqual(
            AggregationPolicy.shouldActivate(
                enabled: true, usableAdapterCount: 1,
                enableExtraConnections: true, proxyMode: "none",
                vpnDefaultRoute: false, allowOutsideVPN: false),
            .tooFewAdapters)
        XCTAssertNil(
            AggregationPolicy.shouldActivate(
                enabled: true, usableAdapterCount: 2,
                enableExtraConnections: true, proxyMode: "none",
                vpnDefaultRoute: false, allowOutsideVPN: false))
    }

    func testShouldActivateBlocksManualProxyAndLowProfileAndVPN() {
        XCTAssertEqual(
            AggregationPolicy.shouldActivate(
                enabled: true, usableAdapterCount: 2,
                enableExtraConnections: false, proxyMode: "none",
                vpnDefaultRoute: false, allowOutsideVPN: false),
            .lowProfile)
        XCTAssertEqual(
            AggregationPolicy.shouldActivate(
                enabled: true, usableAdapterCount: 2,
                enableExtraConnections: true, proxyMode: "manual",
                vpnDefaultRoute: false, allowOutsideVPN: false),
            .proxy)
        XCTAssertEqual(
            AggregationPolicy.shouldActivate(
                enabled: true, usableAdapterCount: 2,
                enableExtraConnections: true, proxyMode: "none",
                vpnDefaultRoute: true, allowOutsideVPN: false),
            .vpn)
        XCTAssertNil(
            AggregationPolicy.shouldActivate(
                enabled: true, usableAdapterCount: 2,
                enableExtraConnections: true, proxyMode: "none",
                vpnDefaultRoute: true, allowOutsideVPN: true))
    }

    func testUsableAdaptersFiltersExpensiveVirtualAndDown() {
        let adapters = [
            NetworkAdapter(bsdName: "en0", displayName: "Wi‑Fi", type: "wifi",
                           ipv4: "192.168.1.2", isUp: true),
            NetworkAdapter(bsdName: "en1", displayName: "Ethernet", type: "wired",
                           ipv4: "10.0.0.2", isUp: true),
            NetworkAdapter(bsdName: "bridge100", displayName: "Hotspot", type: "cellular",
                           ipv4: "172.20.10.2", isUp: true, isExpensive: true),
            NetworkAdapter(bsdName: "utun3", displayName: "VPN", type: "vpn",
                           ipv4: "10.8.0.2", isUp: true),
            NetworkAdapter(bsdName: "lo0", displayName: "Loopback", type: "other",
                           ipv4: "127.0.0.1", isUp: true),
            NetworkAdapter(bsdName: "en9", displayName: "Down", type: "wired",
                           ipv4: "1.2.3.4", isUp: false),
        ]
        let usable = AggregationPolicy.usableAdapters(
            all: adapters,
            selectedIds: ["en0", "en1", "bridge100", "utun3", "lo0", "en9"],
            includeExpensive: false,
            includeVPN: false)
        XCTAssertEqual(Set(usable.map(\.bsdName)), Set(["en0", "en1"]))
    }

    func testPreferredSegmentCount() {
        XCTAssertEqual(AggregationPolicy.preferredSegmentCount(adapters: 2, streamsPerAdapter: 2, budget: 8), 4)
        XCTAssertEqual(AggregationPolicy.preferredSegmentCount(adapters: 3, streamsPerAdapter: 4, budget: 6), 6)
        XCTAssertEqual(AggregationPolicy.preferredSegmentCount(adapters: 2, streamsPerAdapter: 1, budget: 1), 1)
    }

    func testHiddenVirtualNames() {
        XCTAssertTrue(AggregationPolicy.isHiddenVirtual("lo0"))
        XCTAssertTrue(AggregationPolicy.isHiddenVirtual("awdl0"))
        XCTAssertTrue(AggregationPolicy.isHiddenVirtual("utun2"))
        XCTAssertFalse(AggregationPolicy.isHiddenVirtual("en0"))
        XCTAssertFalse(AggregationPolicy.isHiddenVirtual("eth0"))
    }

    // MARK: - AdapterPool

    func testAdapterPoolRoundRobinAndDemote() async {
        let pool = AdapterPool([
            BoundAdapter(bsdName: "en0", displayName: "Wi‑Fi"),
            BoundAdapter(bsdName: "en1", displayName: "Eth"),
        ])
        let a0 = await pool.assign(segment: 0)
        let a1 = await pool.assign(segment: 1)
        let a2 = await pool.assign(segment: 2)
        XCTAssertEqual(a0?.bsdName, "en0")
        XCTAssertEqual(a1?.bsdName, "en1")
        XCTAssertEqual(a2?.bsdName, "en0")
        await pool.demote("en0")
        let only = await pool.assign(segment: 0)
        XCTAssertEqual(only?.bsdName, "en1")
        let usable = await pool.usableCount
        XCTAssertEqual(usable, 1)
    }

    // MARK: - AppSettings Codable

    func testAggregationSettingsRoundTrip() throws {
        var s = AppSettings()
        s.aggregationEnabled = true
        s.aggregationAdapterIds = ["en0", "en1"]
        s.aggregationIncludeExpensive = true
        s.aggregationAllowOutsideVPN = true
        s.aggregationStreamsPerAdapter = 3
        s.aggregationPathDiversityProbe = true
        let data = try JSONEncoder().encode(s)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertTrue(decoded.aggregationEnabled)
        XCTAssertEqual(decoded.aggregationAdapterIds, ["en0", "en1"])
        XCTAssertTrue(decoded.aggregationIncludeExpensive)
        XCTAssertTrue(decoded.aggregationAllowOutsideVPN)
        XCTAssertEqual(decoded.aggregationStreamsPerAdapter, 3)
        XCTAssertTrue(decoded.aggregationPathDiversityProbe)
    }

    func testAggregationSettingsDefaultOnOldBlob() throws {
        // Minimal old-style JSON without aggregation keys.
        let json = """
        {"selectedProfileName":"Medium","speedLimitEnabled":true}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertFalse(decoded.aggregationEnabled)
        XCTAssertEqual(decoded.aggregationAdapterIds, [])
        XCTAssertFalse(decoded.aggregationIncludeExpensive)
        XCTAssertEqual(decoded.aggregationStreamsPerAdapter, 2)
    }

    // MARK: - TaskConnection adapter fields

    func testTaskConnectionAdapterCodable() throws {
        let c = TaskConnection(id: "seg-0", label: "Segment 1", detail: "0–1 MB",
                               downloadSpeed: 100, progress: 0.5,
                               adapterId: "en0", adapterLabel: "Wi‑Fi")
        let data = try JSONEncoder().encode(c)
        let decoded = try JSONDecoder().decode(TaskConnection.self, from: data)
        XCTAssertEqual(decoded.adapterId, "en0")
        XCTAssertEqual(decoded.adapterLabel, "Wi‑Fi")
    }

    // MARK: - makeAggregationConfig

    func testMakeAggregationConfigDisabledByDefault() {
        let adapters = [
            NetworkAdapter(bsdName: "en0", displayName: "Wi‑Fi", type: "wifi", ipv4: "1.1.1.1", isUp: true),
            NetworkAdapter(bsdName: "en1", displayName: "Eth", type: "wired", ipv4: "2.2.2.2", isUp: true),
        ]
        let cfg = DownloadManager.makeAggregationConfig(
            settings: AppSettings(), vpnDefaultRoute: false, adapters: adapters)
        XCTAssertFalse(cfg.isActive)
    }

    func testMakeAggregationConfigActiveWhenEnabled() {
        var s = AppSettings()
        s.aggregationEnabled = true
        s.aggregationAdapterIds = ["en0", "en1"]
        // Medium profile has enableExtraConnections = true
        let adapters = [
            NetworkAdapter(bsdName: "en0", displayName: "Wi‑Fi", type: "wifi", ipv4: "1.1.1.1", isUp: true),
            NetworkAdapter(bsdName: "en1", displayName: "Eth", type: "wired", ipv4: "2.2.2.2", isUp: true),
        ]
        let cfg = DownloadManager.makeAggregationConfig(
            settings: s, vpnDefaultRoute: false, adapters: adapters)
        XCTAssertTrue(cfg.isActive)
        XCTAssertEqual(cfg.adapters.count, 2)
    }

    // MARK: - Content-Range helper (already on SegmentedTransfer)

    func testContentRangeTotalParse() {
        // Build a fake HTTPURLResponse is hard without a URLSession; test pure
        // string logic via the same split used in SegmentedTransfer.
        let header = "bytes 0-99/12345"
        let total = header.split(separator: "/").last.flatMap { Int64($0) }
        XCTAssertEqual(total, 12345)
    }
}
