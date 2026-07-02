import XCTest
@testable import GoelCore

/// Boundary tests for the pure ``AutomationCore/decide(_:)`` — the download
/// window, network policy, scheduled starts, and RSS dedup driven with plain
/// values, no actor / clock / socket / store.
final class AutomationCoreTests: XCTestCase {

    // 2026-07-05 is a Sunday (weekday 1); offset to the wanted weekday.
    private func date(weekday: Int, hour: Int, minute: Int = 0) -> Date {
        var c = DateComponents()
        c.year = 2026; c.month = 7; c.day = 5 + (weekday - 1)
        c.hour = hour; c.minute = minute
        return Calendar.current.date(from: c)!
    }

    private func phase(_ id: UUID, downloading: Bool = false, paused: Bool = false,
                       terminal: Bool = false, scheduledAt: Date? = nil,
                       dedupKey: String = "k") -> AutomationCore.TaskPhase {
        .init(id: id, downloadingPhase: downloading, paused: paused, terminal: terminal,
              scheduledAt: scheduledAt, dedupKey: dedupKey)
    }

    private func snapshot(now: Date, settings: AppSettings,
                          tasks: [AutomationCore.TaskPhase],
                          expensive: Bool = false, constrained: Bool = false,
                          feeds: [AutomationCore.FeedFetch] = [],
                          memory: AutomationCore.Memory = .init()) -> AutomationCore.Snapshot {
        .init(now: now, calendar: .current, settings: settings, tasks: tasks,
              networkExpensive: expensive, networkConstrained: constrained,
              feeds: feeds, memory: memory)
    }

    /// A schedule window 09:00–17:00, every day, activating the `profile` while open.
    private func windowSettings(profile: String = "", selected: String = "Medium") -> AppSettings {
        AppSettings(selectedProfileName: selected,
                    scheduleEnabled: true, scheduleStartMinute: 9 * 60,
                    scheduleEndMinute: 17 * 60, scheduleDays: [1, 2, 3, 4, 5, 6, 7],
                    scheduleProfileName: profile)
    }

    // MARK: Download window

    func testWindowClosePausesActiveSet() {
        let a = UUID(), b = UUID()
        let s = snapshot(now: date(weekday: 3, hour: 18),                 // outside window
                         settings: windowSettings(),
                         tasks: [phase(a, downloading: true), phase(b, downloading: true),
                                 phase(UUID(), paused: true)])            // paused: untouched
        let d = AutomationCore.decide(s)
        XCTAssertEqual(Set(d.actions), [.pause(a, .window), .pause(b, .window)])
        XCTAssertEqual(d.memory.windowPausedIDs, [a, b])
        XCTAssertFalse(d.memory.windowOpen)
    }

    func testWindowOpenRestoresRecordedSet() {
        let a = UUID()
        var mem = AutomationCore.Memory()
        mem.windowOpen = false
        mem.windowPausedIDs = [a]
        let s = snapshot(now: date(weekday: 3, hour: 12),                 // inside window
                         settings: windowSettings(),
                         tasks: [phase(a, paused: true)], memory: mem)
        let d = AutomationCore.decide(s)
        XCTAssertEqual(d.actions, [.resume(a)])
        XCTAssertTrue(d.memory.windowPausedIDs.isEmpty)
        XCTAssertTrue(d.memory.windowOpen)
    }

    func testWindowOpenSwitchesProfileBeforeResuming() {
        let a = UUID()
        var mem = AutomationCore.Memory()
        mem.windowOpen = false
        mem.windowPausedIDs = [a]
        let s = snapshot(now: date(weekday: 3, hour: 12),
                         settings: windowSettings(profile: "High", selected: "Medium"),
                         tasks: [phase(a, paused: true)], memory: mem)
        let d = AutomationCore.decide(s)
        XCTAssertEqual(d.actions, [.activateProfile("High"), .resume(a)])  // profile first
        XCTAssertEqual(d.memory.preWindowProfile, "Medium")               // stashed for restore
    }

    func testWindowCloseRestoresPreWindowProfile() {
        var mem = AutomationCore.Memory()
        mem.windowOpen = true
        mem.preWindowProfile = "Medium"
        let s = snapshot(now: date(weekday: 3, hour: 18),                 // closing
                         settings: windowSettings(profile: "High", selected: "High"),
                         tasks: [], memory: mem)
        let d = AutomationCore.decide(s)
        XCTAssertEqual(d.actions, [.activateProfile("Medium")])
        XCTAssertNil(d.memory.preWindowProfile)
    }

    func testManualProfileChangeWinsOverRestore() {
        var mem = AutomationCore.Memory()
        mem.windowOpen = true
        mem.preWindowProfile = "Medium"
        // Selected is neither the schedule profile — a manual change happened.
        let s = snapshot(now: date(weekday: 3, hour: 18),
                         settings: windowSettings(profile: "High", selected: "Low"),
                         tasks: [], memory: mem)
        let d = AutomationCore.decide(s)
        XCTAssertTrue(d.actions.isEmpty)                                  // no restore
        XCTAssertNil(d.memory.preWindowProfile)                          // but the stash clears
    }

    // MARK: Network awareness

    func testNetworkExpensivePausesThenResumes() {
        let a = UUID()
        let base = AppSettings(pauseOnExpensiveNetwork: true)             // schedule disabled
        let now = date(weekday: 3, hour: 12)
        let pause = AutomationCore.decide(
            snapshot(now: now, settings: base, tasks: [phase(a, downloading: true)],
                     expensive: true))
        XCTAssertEqual(pause.actions, [.pause(a, .network)])
        XCTAssertTrue(pause.memory.networkPaused)
        XCTAssertEqual(pause.memory.networkPausedIDs, [a])

        let resume = AutomationCore.decide(
            snapshot(now: now, settings: base, tasks: [phase(a, paused: true)],
                     expensive: false, memory: pause.memory))
        XCTAssertEqual(resume.actions, [.resume(a)])
        XCTAssertFalse(resume.memory.networkPaused)
        XCTAssertTrue(resume.memory.networkPausedIDs.isEmpty)
    }

    func testWindowAndNetworkSingleAttribution() {
        let a = UUID(), b = UUID()
        var s = windowSettings()                                         // window closing now
        s.pauseOnExpensiveNetwork = true
        let d = AutomationCore.decide(
            snapshot(now: date(weekday: 3, hour: 18), settings: s,
                     tasks: [phase(a, downloading: true), phase(b, downloading: true)],
                     expensive: true))
        // Both claimed by the window; network claims nothing (single attribution).
        XCTAssertEqual(Set(d.actions), [.pause(a, .window), .pause(b, .window)])
        XCTAssertEqual(d.memory.windowPausedIDs, [a, b])
        XCTAssertTrue(d.memory.networkPaused)
        XCTAssertTrue(d.memory.networkPausedIDs.isEmpty)
    }

    // MARK: Scheduled starts

    func testDueScheduledStartFires() {
        let due = UUID(), later = UUID()
        let now = date(weekday: 3, hour: 12)
        let s = snapshot(now: now, settings: AppSettings(),
                         tasks: [phase(due, paused: true, scheduledAt: now.addingTimeInterval(-1)),
                                 phase(later, paused: true, scheduledAt: now.addingTimeInterval(3600))])
        let d = AutomationCore.decide(s)
        XCTAssertEqual(d.actions, [.resume(due)])
    }

    // MARK: RSS

    func testRSSTwoLayerDedup() {
        let src1 = DownloadSource.url(URL(string: "https://example.com/a.bin")!)
        let src2 = DownloadSource.url(URL(string: "https://example.com/b.bin")!)
        // c1 and c2 share a dedupKey (same file, two feed keys); c3 already queued.
        let feed = AutomationCore.FeedFetch(startPaused: true, candidates: [
            .init(key: "f|1", source: src1, dedupKey: src1.dedupKey),
            .init(key: "f|2", source: src1, dedupKey: src1.dedupKey),  // dup dedupKey
            .init(key: "f|3", source: src2, dedupKey: src2.dedupKey),  // already in queue
        ])
        let existing = phase(UUID(), dedupKey: src2.dedupKey)
        let d = AutomationCore.decide(
            snapshot(now: date(weekday: 3, hour: 12), settings: AppSettings(),
                     tasks: [existing], feeds: [feed]))
        XCTAssertEqual(d.actions, [.add(src1, startPaused: true)])       // exactly one add
        XCTAssertEqual(d.memory.rssSeenKeys, ["f|1", "f|2", "f|3"])      // all keys recorded
    }

    func testRSSSkipsAlreadySeenKey() {
        let src = DownloadSource.url(URL(string: "https://example.com/a.bin")!)
        var mem = AutomationCore.Memory()
        mem.rssSeenKeys = ["f|1"]
        let feed = AutomationCore.FeedFetch(startPaused: false, candidates: [
            .init(key: "f|1", source: src, dedupKey: src.dedupKey),
        ])
        let d = AutomationCore.decide(
            snapshot(now: date(weekday: 3, hour: 12), settings: AppSettings(),
                     tasks: [], feeds: [feed], memory: mem))
        XCTAssertTrue(d.actions.isEmpty)
    }
}
