import XCTest
@testable import GoelCore

final class NetworkSelectionTests: XCTestCase {

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
        XCTAssertThrowsError(
            try JSONDecoder().decode(NetworkSelection.self, from: Data("\"single:\"".utf8)))
        XCTAssertThrowsError(
            try JSONDecoder().decode(NetworkSelection.self, from: Data("\"nonsense\"".utf8)))
    }

    func testTaskWithoutTheFieldStillDecodes() throws {
        let original = DownloadTask(
            source: .url(URL(string: "https://example.test/a")!),
            name: "a", saveDirectory: "/tmp")
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

    private func bound(_ names: String...) -> [BoundAdapter] {
        names.map { BoundAdapter(bsdName: $0, displayName: $0) }
    }

    /// Every binding outcome, including the exact note the UI shows — a reworded note is a UI regression.
    func testBindTargetsResolvesEverySelectionAgainstWhatIsAvailable() {
        let cases: [(label: String, selection: NetworkSelection?,
                     defaults: [BoundAdapter], available: [BoundAdapter],
                     expected: [String], note: String?)] = [
            ("auto defers to the policy",
             .auto, bound("eth0"), bound("eth0", "wlan0"), ["eth0"], nil),
            ("nil behaves like auto",
             nil, [], bound("eth0", "wlan0"), [], nil),
            ("single pins even with aggregation off",
             .single("wlan0"), [], bound("eth0", "wlan0"), ["wlan0"], nil),
            ("a missing interface falls back and says so",
             .single("usb0"), bound("eth0"), bound("eth0"), ["eth0"],
             "usb0 is not available — using the default route instead."),
            ("aggregate with no names uses everything available",
             .aggregate([]), [], bound("eth0", "wlan0"), ["eth0", "wlan0"], nil),
            ("aggregate keeps the named order and reports skips",
             .aggregate(["wlan0", "eth0", "usb0"]), [], bound("eth0", "wlan0"), ["wlan0", "eth0"],
             "Skipping usb0 — not available."),
            ("aggregate down to one interface still runs on it",
             .aggregate(["eth0", "usb0"]), [], bound("eth0"), ["eth0"],
             "Running on one interface — usb0 unavailable."),
            ("aggregate with nothing left falls back to the default",
             .aggregate(["usb0"]), bound("eth0"), bound("eth0"), ["eth0"],
             "Cannot split this download — usb0 unavailable. Using the default route."),
            ("aggregate with no eligible interfaces at all",
             .aggregate([]), [], [], [],
             "Cannot split this download — no interfaces are eligible. Using the default route."),
        ]
        for c in cases {
            let result = AggregationPolicy.bindTargets(
                for: c.selection, defaultAdapters: c.defaults, available: c.available)
            XCTAssertEqual(result.adapters.map(\.bsdName), c.expected, c.label)
            XCTAssertEqual(result.note, c.note, c.label)
        }
    }
}
