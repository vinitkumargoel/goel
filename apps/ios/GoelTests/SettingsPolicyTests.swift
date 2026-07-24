import Foundation
import Testing
@testable import Goel

/// The parts of Settings that are rules rather than pixels.
///
/// Everything here is a pure function or a `UserDefaults` round trip, which is the point: the
/// month boundary, the connection clamp and the speed-limit table are the three places where a
/// wrong answer is invisible until a user hits it, so none of them may depend on a simulator, a
/// wall clock, or the device's own calendar.
@Suite("Settings policy")
struct SettingsPolicyTests {

    // MARK: - Fixtures

    /// A fixed Gregorian/UTC calendar. The device's own `Calendar.current` would make these
    /// tests pass or fail depending on the machine's time zone at the month boundary.
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        let components = DateComponents(year: year, month: month, day: day)
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    /// An isolated defaults suite per test, torn down afterwards so nothing leaks between runs
    /// or into the real app domain.
    private static func withScratchDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "dev.goel.ios.tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            Issue.record("Could not create a UserDefaults suite named \(name)")
            return
        }
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    // MARK: - Month rollover

    @Test("The counter survives the month it belongs to")
    func counterSurvivesItsOwnMonth() {
        let start = Self.date(2026, 1, 1)
        let snapshot = CellularDataLedger.Snapshot(bytes: 1_400_000_000, periodStart: start)

        for day in [1, 5, 28, 31] {
            let unchanged = CellularDataLedger.rollingOver(
                snapshot,
                now: Self.date(2026, 1, day),
                calendar: Self.calendar
            )
            #expect(unchanged == snapshot, "January \(day) is still January")
        }
    }

    @Test("The counter resets when the calendar month changes")
    func counterResetsAcrossTheBoundary() {
        let snapshot = CellularDataLedger.Snapshot(
            bytes: 1_400_000_000,
            periodStart: Self.date(2026, 1, 28)
        )

        let february = CellularDataLedger.rollingOver(
            snapshot,
            now: Self.date(2026, 2, 1),
            calendar: Self.calendar
        )
        #expect(february.bytes == 0)
        #expect(february.periodStart == Self.date(2026, 2, 1))

        // A month index alone is not a period: January 2027 is not January 2026.
        let nextYear = CellularDataLedger.rollingOver(
            snapshot,
            now: Self.date(2027, 1, 3),
            calendar: Self.calendar
        )
        #expect(nextYear.bytes == 0)
        #expect(nextYear.periodStart == Self.date(2027, 1, 1))
    }

    @Test("Recording bytes accumulates inside a month and starts over after it")
    func recordingAccumulatesThenResets() {
        Self.withScratchDefaults { defaults in
            let january = Self.date(2026, 1, 10)
            _ = CellularDataLedger.record(400_000, in: defaults, now: january, calendar: Self.calendar)
            let second = CellularDataLedger.record(600_000, in: defaults, now: january, calendar: Self.calendar)
            #expect(second.bytes == 1_000_000)

            let february = CellularDataLedger.load(
                from: defaults,
                now: Self.date(2026, 2, 2),
                calendar: Self.calendar
            )
            #expect(february.bytes == 0)
            #expect(february.periodStart == Self.date(2026, 2, 1))
        }
    }

    // MARK: - EngineTuning persistence

    @Test("EngineTuning round-trips through save and load")
    func tuningRoundTrips() {
        Self.withScratchDefaults { defaults in
            #expect(EngineTuning.load(from: defaults) == .default, "An empty suite yields the defaults")

            let tuning = EngineTuning(
                trafficProfile: .aggressive,
                maxConnections: 3,
                speedLimitBytesPerSec: 5_000_000,
                allowCellular: true,
                finishOnWiFi: false,
                verifyChecksums: false
            )
            tuning.save(to: defaults)

            #expect(EngineTuning.load(from: defaults) == tuning)
        }
    }

    @Test("An unlimited speed limit round-trips as nil, not as zero")
    func unlimitedRoundTrips() {
        Self.withScratchDefaults { defaults in
            let tuning = EngineTuning(speedLimitBytesPerSec: nil)
            tuning.save(to: defaults)
            #expect(EngineTuning.load(from: defaults).speedLimitBytesPerSec == nil)
        }
    }

    // MARK: - Connection clamp

    @Test("maxConnections clamps to 1...8", arguments: [
        (0, 1), (-4, 1), (1, 1), (6, 6), (8, 8), (9, 8), (64, 8),
    ])
    func connectionsClamp(requested: Int, expected: Int) {
        #expect(EngineTuning(maxConnections: requested).maxConnections == expected)
        #expect(TrafficProfilePolicy.clampConnections(requested) == expected)
    }

    @Test("The stepper's range and the tuning clamp agree")
    func rangeMatchesClamp() {
        #expect(TrafficProfilePolicy.connectionRange == 1...8)
    }

    // MARK: - Speed limit table

    @Test("Speed-limit options map to base-10 byte counts")
    func speedLimitValues() {
        #expect(SpeedLimitOption.off.bytesPerSecond == nil)
        #expect(SpeedLimitOption.oneMBps.bytesPerSecond == 1_000_000)
        #expect(SpeedLimitOption.fiveMBps.bytesPerSecond == 5_000_000)
        #expect(SpeedLimitOption.tenMBps.bytesPerSecond == 10_000_000)
        #expect(SpeedLimitOption.twentyFiveMBps.bytesPerSecond == 25_000_000)

        #expect(SpeedLimitOption.off.displayName == "Off")
        #expect(SpeedLimitOption.oneMBps.displayName == "1 MB/s")
        #expect(SpeedLimitOption.twentyFiveMBps.displayName == "25 MB/s")

        #expect(SpeedLimitOption.allCases.count == 5)
    }

    @Test("A stored rate reads back as the option that produced it")
    func speedLimitRoundTrips() {
        for option in SpeedLimitOption.allCases {
            #expect(SpeedLimitOption(bytesPerSecond: option.bytesPerSecond) == option)
        }
        // Values from a hand-edited or older store still land on a real menu entry.
        #expect(SpeedLimitOption(bytesPerSecond: 0) == .off)
        #expect(SpeedLimitOption(bytesPerSecond: -1) == .off)
        #expect(SpeedLimitOption(bytesPerSecond: 3_000_000) == .oneMBps)
        #expect(SpeedLimitOption(bytesPerSecond: 900_000_000) == .twentyFiveMBps)
    }

    // MARK: - Traffic profile

    @Test("Traffic profiles carry the connection counts the mockup promises")
    func profileConnectionCounts() {
        #expect(TrafficProfile.conservative.connections == 2)
        #expect(TrafficProfile.balanced.connections == 6)
        #expect(TrafficProfile.aggressive.connections == 8)
    }

    @Test("Choosing a profile moves the connection count with it")
    func profileDrivesConnections() {
        let conservative = TrafficProfilePolicy.applying(.conservative, to: .default)
        #expect(conservative.trafficProfile == .conservative)
        #expect(conservative.maxConnections == 2)

        let aggressive = TrafficProfilePolicy.applying(.aggressive, to: conservative)
        #expect(aggressive.trafficProfile == .aggressive)
        #expect(aggressive.maxConnections == 8)
    }

    @Test("Applying a profile leaves every unrelated setting alone")
    func profilePreservesEverythingElse() {
        let before = EngineTuning(
            trafficProfile: .balanced,
            maxConnections: 6,
            speedLimitBytesPerSec: 10_000_000,
            allowCellular: true,
            finishOnWiFi: false,
            verifyChecksums: false
        )
        let after = TrafficProfilePolicy.applying(.conservative, to: before)

        #expect(after.speedLimitBytesPerSec == before.speedLimitBytesPerSec)
        #expect(after.allowCellular == before.allowCellular)
        #expect(after.finishOnWiFi == before.finishOnWiFi)
        #expect(after.verifyChecksums == before.verifyChecksums)
    }
}

// MARK: - Link validation

/// The add sheet's half of the honesty contract: a link that cannot work is refused in words,
/// here, rather than accepted and failed later. `file://` is the case the desktop facade rejects
/// too, and it must never reach the queue.
@Suite("Add sheet link validation")
struct AddSheetValidationTests {

    @Test("http and https parse")
    func acceptsWebSchemes() {
        #expect(LinkValidation.check("http://localhost:8099/test-200mb.bin").url != nil)
        #expect(LinkValidation.check("https://releases.ubuntu.com/24.04.1/ubuntu-24.04.1-desktop-amd64.iso").url != nil)
        #expect(LinkValidation.check("  https://example.com/file.zip  ").url != nil, "Surrounding whitespace is trimmed")
    }

    @Test("An empty field is not an error")
    func emptyIsNotAnError() {
        #expect(LinkValidation.check("") == .empty)
        #expect(LinkValidation.check("   ") == .empty)
        #expect(LinkValidation.check("").message == nil)
        #expect(LinkValidation.check("").isUsable == false)
    }

    @Test("file:// is refused, with a sentence")
    func refusesFileScheme() {
        let result = LinkValidation.check("file:///Users/vinit/Downloads/ubuntu.iso")
        #expect(result.url == nil)
        #expect(result.message == TransferError.unsupportedScheme("file").userMessage)
    }

    @Test("Other schemes are refused too", arguments: [
        "ftp://example.com/f.bin",
        "sftp://example.com/f.bin",
        "magnet:?xt=urn:btih:abc",
        "javascript:alert(1)",
    ])
    func refusesOtherSchemes(raw: String) {
        #expect(LinkValidation.check(raw).url == nil)
        #expect(LinkValidation.check(raw).message != nil)
    }

    @Test("A schemeless or hostless string is refused", arguments: [
        "releases.ubuntu.com/file.iso",
        "http://",
        "https://",
        "not a link at all",
    ])
    func refusesUnparseable(raw: String) {
        let result = LinkValidation.check(raw)
        #expect(result.url == nil)
        #expect(result.isUsable == false)
        #expect(result.message?.isEmpty == false, "Every refusal carries a sentence")
    }
}
