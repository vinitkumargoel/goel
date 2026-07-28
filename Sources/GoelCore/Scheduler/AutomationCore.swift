import Foundation

enum AutomationCore {

    struct TaskPhase: Sendable, Equatable {
        var id: UUID
        /// `.downloading` / `.verifying` / `.requestingMetadata` — never seeding.
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

    struct FeedCandidate: Sendable, Equatable {
        var key: String
        var source: DownloadSource
        var dedupKey: String // must equal source.dedupKey; precomputed by the caller

        init(key: String, source: DownloadSource, dedupKey: String) {
            self.key = key
            self.source = source
            self.dedupKey = dedupKey
        }
    }

    struct FeedFetch: Sendable, Equatable {
        var startPaused: Bool
        var candidates: [FeedCandidate]

        init(startPaused: Bool, candidates: [FeedCandidate]) {
            self.startPaused = startPaused
            self.candidates = candidates
        }
    }

    struct Memory: Sendable, Equatable {
        var windowOpen = true
        var windowPausedIDs: Set<UUID> = []
        var preWindowProfile: String?
        var networkPaused = false
        var networkPausedIDs: Set<UUID> = []
        var powerPaused = false
        var powerPausedIDs: Set<UUID> = []
        var rssSeenKeys: Set<String> = []

        init() {}
    }

    /// Lets the manager un-record a pause it could not apply (task changed phase across an `await`).
    enum Ledger: Sendable, Equatable, Hashable { case window, network, power }

    enum Action: Sendable, Equatable, Hashable {
        case pause(UUID, Ledger)
        case resume(UUID)
        /// Must bypass the full `updateSettings` cascade — this is the recursion seam.
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
        var onBattery: Bool
        /// A missing level reads as full, so a desktop is never paused.
        var batteryPercent: Int?
        var feeds: [FeedFetch]
        var memory: Memory

        init(now: Date, calendar: Calendar, settings: AppSettings,
                    tasks: [TaskPhase], networkExpensive: Bool, networkConstrained: Bool,
                    onBattery: Bool = false, batteryPercent: Int? = nil,
                    feeds: [FeedFetch] = [], memory: Memory) {
            self.now = now
            self.calendar = calendar
            self.settings = settings
            self.tasks = tasks
            self.networkExpensive = networkExpensive
            self.networkConstrained = networkConstrained
            self.onBattery = onBattery
            self.batteryPercent = batteryPercent
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

    /// Policy order is fixed — window, network, battery, scheduled, RSS — so one ledger claims a task per tick.
    static func decide(_ s: Snapshot) -> Decision {
        var memory = s.memory
        var actions: [Action] = []
        var claimedThisTick: Set<UUID> = []

        let desiredOpen = isWindowOpen(settings: s.settings, date: s.now, calendar: s.calendar)
        if desiredOpen != memory.windowOpen {
            if desiredOpen {
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
                // Record each pause, or reopening resumes a task the user paused by hand.
                if let previous = memory.preWindowProfile {
                    memory.preWindowProfile = nil
                    // Only restore if the window's profile is still active: a manual change wins.
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

        let shouldPause = (s.settings.pauseOnExpensiveNetwork && s.networkExpensive)
            || (s.settings.pauseOnConstrainedNetwork && s.networkConstrained)
        if shouldPause, !memory.networkPaused {
            var paused: Set<UUID> = []
            for t in s.tasks where t.downloadingPhase && !claimedThisTick.contains(t.id) {
                actions.append(.pause(t.id, .network))
                paused.insert(t.id)
                claimedThisTick.insert(t.id)
            }
            // Latch only if something was paused: an empty latch consumes the policy for good.
            if !paused.isEmpty {
                memory.networkPaused = true
                memory.networkPausedIDs = paused
            }
        } else if !shouldPause, memory.networkPaused {
            memory.networkPaused = false
            for id in memory.networkPausedIDs.sortedByUUID() { actions.append(.resume(id)) }
            memory.networkPausedIDs = []
        }

        let batteryLow = s.settings.pauseBelowBatteryThreshold
            && s.onBattery
            && (s.batteryPercent ?? 100) <= s.settings.batteryThresholdPercent
        if batteryLow, !memory.powerPaused {
            var paused: Set<UUID> = []
            for t in s.tasks where t.downloadingPhase && !claimedThisTick.contains(t.id) {
                actions.append(.pause(t.id, .power))
                paused.insert(t.id)
                claimedThisTick.insert(t.id)
            }
            if !paused.isEmpty {
                memory.powerPaused = true
                memory.powerPausedIDs = paused
            }
        } else if !batteryLow, memory.powerPaused {
            memory.powerPaused = false
            for id in memory.powerPausedIDs.sortedByUUID() { actions.append(.resume(id)) }
            memory.powerPausedIDs = []
        }

        for t in s.tasks where t.paused && (t.scheduledAt ?? .distantFuture) <= s.now {
            actions.append(.resume(t.id))
        }

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

    /// start == end means always open; end < start wraps past midnight (22:00 → 07:00).
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
        // The `< end` portion belongs to yesterday's window: gate on yesterday's weekday.
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
    func sortedByUUID() -> [UUID] { sorted { $0.uuidString < $1.uuidString } }
}
