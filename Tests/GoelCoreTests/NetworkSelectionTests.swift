import XCTest
@testable import GoelCore

/// The `--net` / `network:` grammar is shared by the CLI, the JSON API and the persisted task blob,
/// and names an interface reaching `SO_BINDTODEVICE` as a C string — pin both parse and reject.
final class NetworkSelectionTests: XCTestCase {

    // MARK: Parsing

    func testAutoIsTheEmptyAndExplicitForm() {
        XCTAssertEqual(NetworkSelection(spec: ""), .auto)
        XCTAssertEqual(NetworkSelection(spec: "   "), .auto)
        XCTAssertEqual(NetworkSelection(spec: "auto"), .auto)
        XCTAssertEqual(NetworkSelection(spec: "AUTO"), .auto)
    }

    func testSingleAndAggregate() {
        XCTAssertEqual(NetworkSelection(spec: "single:eth0"), .single("eth0"))
        XCTAssertEqual(NetworkSelection(spec: "aggregate"), .aggregate([]))
        XCTAssertEqual(NetworkSelection(spec: "aggregate:eth0,wlan0"),
                       .aggregate(["eth0", "wlan0"]))
        XCTAssertEqual(NetworkSelection(spec: "aggregate: eth0 , wlan0 "),
                       .aggregate(["eth0", "wlan0"]))
    }

    /// One interface under `aggregate` is a pin, so the engine never has to
    /// special-case a "spread" of size one.
    func testSingletonAggregateNormalisesToSingle() {
        XCTAssertEqual(NetworkSelection(spec: "aggregate:eth0"), .single("eth0"))
        XCTAssertEqual(NetworkSelection(spec: "aggregate:eth0,,"), .single("eth0"))
    }

    func testMalformedSpecsAreRejectedRatherThanTreatedAsAuto() {
        for bad in ["single:", "single", "bogus", "single:eth 0", "single:et/../h0",
                    "single:abcdefghijklmnopq", "aggregate:eth0,bad iface", "single:eth\u{0}0"] {
            XCTAssertNil(NetworkSelection(spec: bad), "‘\(bad)’ should not parse")
        }
    }

    func testInterfaceNameLengthMatchesIFNAMSIZ() {
        XCTAssertTrue(NetworkSelection.isValidInterfaceName(String(repeating: "a", count: 15)))
        XCTAssertFalse(NetworkSelection.isValidInterfaceName(String(repeating: "a", count: 16)))
        XCTAssertFalse(NetworkSelection.isValidInterfaceName(""))
    }

    // MARK: Round trip

    func testSpecRoundTrips() {
        for value: NetworkSelection in [.auto, .single("wlp13s0"), .aggregate([]),
                                        .aggregate(["eth0", "wlan0"])] {
            XCTAssertEqual(NetworkSelection(spec: value.spec), value)
        }
    }

    func testCodableUsesTheSameSingleString() throws {
        let encoded = try JSONEncoder().encode(NetworkSelection.single("eth0"))
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"single:eth0\"")
        XCTAssertEqual(try JSONDecoder().decode(NetworkSelection.self, from: encoded),
                       .single("eth0"))
    }

    func testDecodingGarbageThrowsRatherThanSilentlyBecomingAuto() {
        // Valid JSON, invalid spec: the failure must come from the grammar, not
        // from the parser choking on the envelope.
        XCTAssertThrowsError(
            try JSONDecoder().decode(NetworkSelection.self, from: Data("\"single:\"".utf8)))
        XCTAssertThrowsError(
            try JSONDecoder().decode(NetworkSelection.self, from: Data("\"nonsense\"".utf8)))
    }

    /// Tasks are stored as JSON blobs with no schema migration, so a task written
    /// before this field existed has to keep decoding.
    func testTaskWithoutTheFieldStillDecodes() throws {
        let original = DownloadTask(
            source: .url(URL(string: "https://example.test/a")!),
            name: "a", saveDirectory: "/tmp")
        // Re-encode with the key stripped, exactly as a pre-feature row on disk looks.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(original)) as? [String: Any])
        object.removeValue(forKey: "networkSelection")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(DownloadTask.self, from: legacy)
        XCTAssertNil(decoded.networkSelection)
        XCTAssertEqual(decoded.id, original.id)
    }

    func testTaskRoundTripsTheSelection() throws {
        var task = DownloadTask(
            source: .url(URL(string: "https://example.test/a")!),
            name: "a", saveDirectory: "/tmp")
        task.networkSelection = .aggregate(["eth0", "wlan0"])
        let decoded = try JSONDecoder().decode(
            DownloadTask.self, from: try JSONEncoder().encode(task))
        XCTAssertEqual(decoded.networkSelection, .aggregate(["eth0", "wlan0"]))
    }

    // MARK: Resolution against live interfaces

    private func bound(_ names: String...) -> [BoundAdapter] {
        names.map { BoundAdapter(bsdName: $0, displayName: $0) }
    }

    func testAutoDefersToThePolicy() {
        let result = AggregationPolicy.bindTargets(
            for: .auto, defaultAdapters: bound("eth0"), available: bound("eth0", "wlan0"))
        XCTAssertEqual(result.adapters.map(\.bsdName), ["eth0"])
        XCTAssertNil(result.note)
    }

    func testNilSelectionBehavesLikeAuto() {
        let result = AggregationPolicy.bindTargets(
            for: nil, defaultAdapters: [], available: bound("eth0", "wlan0"))
        XCTAssertTrue(result.adapters.isEmpty)
        XCTAssertNil(result.note)
    }

    /// A pin has to work even when the server-wide policy binds nothing at all —
    /// that is the whole point of choosing per download.
    func testSinglePinsEvenWithAggregationOff() {
        let result = AggregationPolicy.bindTargets(
            for: .single("wlan0"), defaultAdapters: [], available: bound("eth0", "wlan0"))
        XCTAssertEqual(result.adapters.map(\.bsdName), ["wlan0"])
        XCTAssertNil(result.note)
    }

    /// A cable pulled between queueing and starting must degrade, not fail.
    func testMissingInterfaceFallsBackAndSaysSo() {
        let result = AggregationPolicy.bindTargets(
            for: .single("usb0"), defaultAdapters: bound("eth0"), available: bound("eth0"))
        XCTAssertEqual(result.adapters.map(\.bsdName), ["eth0"])
        XCTAssertEqual(result.note, "usb0 is not available — using the default route instead.")
    }

    func testAggregateWithNoNamesUsesEverythingAvailable() {
        let result = AggregationPolicy.bindTargets(
            for: .aggregate([]), defaultAdapters: [], available: bound("eth0", "wlan0"))
        XCTAssertEqual(result.adapters.map(\.bsdName), ["eth0", "wlan0"])
        XCTAssertNil(result.note)
    }

    func testAggregateKeepsTheNamedOrderAndReportsSkips() {
        let result = AggregationPolicy.bindTargets(
            for: .aggregate(["wlan0", "eth0", "usb0"]),
            defaultAdapters: [], available: bound("eth0", "wlan0"))
        XCTAssertEqual(result.adapters.map(\.bsdName), ["wlan0", "eth0"])
        XCTAssertEqual(result.note, "Skipping usb0 — not available.")
    }

    func testAggregateDownToOneInterfaceStillRunsOnIt() {
        let result = AggregationPolicy.bindTargets(
            for: .aggregate(["eth0", "usb0"]), defaultAdapters: [], available: bound("eth0"))
        XCTAssertEqual(result.adapters.map(\.bsdName), ["eth0"])
        XCTAssertEqual(result.note, "Running on one interface — usb0 unavailable.")
    }

    func testAggregateWithNothingLeftFallsBackToTheDefault() {
        let result = AggregationPolicy.bindTargets(
            for: .aggregate(["usb0"]), defaultAdapters: bound("eth0"), available: bound("eth0"))
        XCTAssertEqual(result.adapters.map(\.bsdName), ["eth0"])
        XCTAssertEqual(result.note,
                       "Cannot split this download — usb0 unavailable. Using the default route.")
    }

    func testAggregateWithNoEligibleInterfacesAtAll() {
        let result = AggregationPolicy.bindTargets(
            for: .aggregate([]), defaultAdapters: [], available: [])
        XCTAssertTrue(result.adapters.isEmpty)
        XCTAssertEqual(result.note,
                       "Cannot split this download — no interfaces are eligible. Using the default route.")
    }
}
