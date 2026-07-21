import Foundation

/// The pure decision core for the scheduler's timer-driven automation.
///
/// Given an immutable ``Snapshot`` — the current time, settings, a lightweight
/// projection of the task list, the last-reported network path, any pre-fetched
/// feed items, and the prior automation ``Memory`` — ``decide(_:)`` returns the
/// ordered ``Action``s to apply **and** the next ``Memory``. The manager only
/// applies the actions (re-validating each across its `await`s) and round-trips
/// the memory; every day/time/network/schedule/RSS decision lives here, drivable
/// by plain-value unit tests with no actor, clock, engine, socket, or store.
///
/// The five parallel bookkeeping ledgers the manager used to keep
/// (`schedulePausedIDs`, `preScheduleProfileName`, `networkPaused`,
/// `networkPausedIDs`, `rssSeenKeys`) are consolidated into the single
/// ``Memory`` value, so they can never drift apart.
enum AutomationCore {

    /// The only per-task data ``decide(_:)`` needs — a projection, so the 24-field
    /// ``DownloadTask`` never enters the decision core and test construction stays
    /// trivial.
    struct TaskPhase: Sendable, Equatable {
        var id: UUID
        /// In a download phase the window/network policies act on
        /// (`.downloading` / `.verifying` / `.requestingMetadata` — never seeding).
        var downloadingPhase: Bool
        var paused: Bool
        var terminal: Bool
        var scheduledAt: Date?
        var dedupKey: String

        init(id: UUID, downloadingPhase: Bool, paused: Bool, terminal: Bool,
                    scheduledAt: Date?, dedupKey: String) {
            self.id = id
            self.downloadingPhase = downloadingPhase
            self.paused = paused
            self.terminal = terminal
            self.scheduledAt = scheduledAt
            self.dedupKey = dedupKey
        }
    }

    /// One already-fetched, already-title-matched feed item.
    struct FeedCandidate: Sendable, Equatable {
        var key: String // per-run identity: "feedID|guid-or-locator"
        var source: DownloadSource
        var dedupKey: String // == source.dedupKey, precomputed by the caller

        init(key: String, source: DownloadSource, dedupKey: String) {
            self.key = key
            self.source = source
            self.dedupKey = dedupKey
        }
    }

    /// A feed's contribution to a poll: its `startPaused` flag plus the candidates
    /// that survived the title filter. The impure fetch/parse stays in the manager.
    struct FeedFetch: Sendable, Equatable {
        var startPaused: Bool
        var candidates: [FeedCandidate]

        init(startPaused: Bool, candidates: [FeedCandidate]) {
            self.startPaused = startPaused
            self.candidates = candidates
        }
    }

    /// The consolidated automation state — replaces all five parallel ledgers.
    struct Memory: Sendable, Equatable {
        /// Whether the download window was open as of the last decision.
        var windowOpen = true
        /// Tasks the window-close paused, so reopening resumes exactly those.
        var windowPausedIDs: Set<UUID> = []
        /// The profile active before the window switched to its own, restored on close.
        var preWindowProfile: String?
        /// Whether the network policy currently holds the queue paused.
        var networkPaused = false
        /// Tasks the network policy paused, so recovery resumes exactly those.
        var networkPausedIDs: Set<UUID> = []
        /// Feed item keys already queued this run, so a poll never re-adds items.
        var rssSeenKeys: Set<String> = []

        init() {}
    }

    /// Which policy paused a task — so the manager can un-record a pause it could
    /// not actually apply (the task changed phase across an `await`).
    enum Ledger: Sendable, Equatable, Hashable { case window, network }

    enum Action: Sendable, Equatable, Hashable {
        case pause(UUID, Ledger)
        case resume(UUID)
        /// Narrow set-active-profile + persist + push-to-engines (bypasses the full
        /// `updateSettings` cascade — the deliberate recursion seam).
        case activateProfile(String)
        case add(DownloadSource, startPaused: Bool)
    }

    struct Snapshot: Sendable {
        var now: Date
        var calendar: Calendar
        var settings: AppSettings
        var tasks: [TaskPhase]
        var networkExpensive: Bool
        var networkConstrained: Bool
        var feeds: [FeedFetch]
        var memory: Memory

        init(now: Date, calendar: Calendar, settings: AppSettings,
                    tasks: [TaskPhase], networkExpensive: Bool, networkConstrained: Bool,
                    feeds: [FeedFetch] = [], memory: Memory) {
            self.now = now
            self.calendar = calendar
            self.settings = settings
            self.tasks = tasks
            self.networkExpensive = networkExpensive
            self.networkConstrained = networkConstrained
            self.feeds = feeds
            self.memory = memory
        }
    }

    struct Decision: Sendable, Equatable {
        var actions: [Action]
        var memory: Memory

        init(actions: [Action], memory: Memory) {
            self.actions = actions
            self.memory = memory
        }
    }

    /// The one entry point: pure and total over its ``Snapshot``.
    ///
    /// Policies are evaluated in a fixed order — download window, then network
    /// awareness, then per-task scheduled starts, then RSS — and a task is
    /// pause-claimed by at most one ledger per tick (window wins), so a paused id
    /// is attributed to a single owner and recovers deterministically.
    static func decide(_ s: Snapshot) -> Decision {
        var memory = s.memory
        var actions: [Action] = []
        var claimedThisTick: Set<UUID> = []

        // MARK: Download window
        let desiredOpen = isWindowOpen(settings: s.settings, date: s.now, calendar: s.calendar)
        if desiredOpen != memory.windowOpen {
            if desiredOpen {
                // Opening: switch to the schedule's profile, then resume exactly
                // the tasks the window itself paused.
                let scheduleProfile = s.settings.scheduleProfileName
                if !scheduleProfile.isEmpty,
                   s.settings.profiles.contains(where: { $0.name == scheduleProfile }),
                   s.settings.selectedProfileName != scheduleProfile {
                    memory.preWindowProfile = s.settings.selectedProfileName
                    actions.append(.activateProfile(scheduleProfile))
                }
                for id in memory.windowPausedIDs.sortedByUUID() { actions.append(.resume(id)) }
                memory.windowPausedIDs = []
                memory.windowOpen = true
            } else {
                // Closing: restore the pre-window profile, then pause every
                // downloading-phase task (recording it, so a hand-paused task is
                // never resumed by the window).
                if let previous = memory.preWindowProfile {
                    memory.preWindowProfile = nil
                    // Only restore if the window's own profile is still active — a
                    // manual profile change made while the window was open wins.
                    if s.settings.selectedProfileName == s.settings.scheduleProfileName,
                       s.settings.profiles.contains(where: { $0.name == previous }) {
                        actions.append(.activateProfile(previous))
                    }
                }
                var paused: Set<UUID> = []
                for t in s.tasks where t.downloadingPhase {
                    actions.append(.pause(t.id, .window))
                    paused.insert(t.id)
                    claimedThisTick.insert(t.id)
                }
                memory.windowPausedIDs = paused
                memory.windowOpen = false
            }
        }

        // MARK: Network awareness
        let shouldPause = (s.settings.pauseOnExpensiveNetwork && s.networkExpensive)
            || (s.settings.pauseOnConstrainedNetwork && s.networkConstrained)
        if shouldPause, !memory.networkPaused {
            var paused: Set<UUID> = []
            for t in s.tasks where t.downloadingPhase && !claimedThisTick.contains(t.id) {
                actions.append(.pause(t.id, .network))
                paused.insert(t.id)
                claimedThisTick.insert(t.id)
            }
            // Only latch the policy once it has actually paused something. If every
            // downloading-phase task is already paused by another ledger (e.g. the
            // window), latching now with an empty set would "consume" the policy —
            // when those tasks later resume over the still-expensive network, this
            // branch would be skipped (`memory.networkPaused` already true) and they
            // would never be re-paused. Leaving it unlatched lets the next tick pause
            // the resumed task.
            if !paused.isEmpty {
                memory.networkPaused = true
                memory.networkPausedIDs = paused
            }
        } else if !shouldPause, memory.networkPaused {
            memory.networkPaused = false
            for id in memory.networkPausedIDs.sortedByUUID() { actions.append(.resume(id)) }
            memory.networkPausedIDs = []
        }

        // MARK: Per-task scheduled starts
        for t in s.tasks where t.paused && (t.scheduledAt ?? .distantFuture) <= s.now {
            actions.append(.resume(t.id))
        }

        // MARK: RSS auto-download (two-layer dedup: per-run key set ∪ existing queue)
        var addedThisTick: Set<String> = []
        for feed in s.feeds {
            for cand in feed.candidates {
                guard !memory.rssSeenKeys.contains(cand.key) else { continue }
                memory.rssSeenKeys.insert(cand.key)
                let existing = s.tasks.contains { $0.dedupKey == cand.dedupKey }
                    || addedThisTick.contains(cand.dedupKey)
                guard !existing else { continue }
                addedThisTick.insert(cand.dedupKey)
                actions.append(.add(cand.source, startPaused: feed.startPaused))
            }
        }

        return Decision(actions: actions, memory: memory)
    }

    /// Whether the download window is open at `date` under `settings`. Pure so
    /// tests can drive the day/time matrix directly. A disabled schedule — or a
    /// degenerate window whose start equals its end — is always open; an end
    /// before the start wraps past midnight (22:00 → 07:00).
    static func isWindowOpen(settings: AppSettings, date: Date,
                                    calendar: Calendar = .current) -> Bool {
        guard settings.scheduleEnabled else { return true }
        let start = settings.scheduleStartMinute
        let end = settings.scheduleEndMinute
        guard start != end else { return true }
        let minutes = calendar.component(.hour, from: date) * 60
            + calendar.component(.minute, from: date)
        let today = calendar.component(.weekday, from: date)
        if start < end {
            return settings.scheduleDays.contains(today) && minutes >= start && minutes < end
        }
        // Wrap-around window (e.g. 22:00 → 07:00). The evening portion (`>= start`)
        // belongs to today; the early-morning portion (`< end`) belongs to the
        // window that *started* the previous calendar day, so it must be gated on
        // yesterday's weekday — otherwise an overnight window from an included day
        // (e.g. Fri) wrongly closes at midnight when the next day (Sat) is excluded.
        if minutes >= start {
            return settings.scheduleDays.contains(today)
        }
        if minutes < end {
            let yesterday = calendar.date(byAdding: .day, value: -1, to: date) ?? date
            return settings.scheduleDays.contains(calendar.component(.weekday, from: yesterday))
        }
        return false
    }
}

private extension Set where Element == UUID {
    /// A deterministic ordering for set-derived resume actions (so a ``Decision``
    /// is stable/testable). Resume order is otherwise immaterial to behaviour.
    func sortedByUUID() -> [UUID] { sorted { $0.uuidString < $1.uuidString } }
}
