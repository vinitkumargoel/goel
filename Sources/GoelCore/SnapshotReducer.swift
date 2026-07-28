import Foundation

public enum SnapshotReducer {

    public static func reduce(_ prev: ReducerState,
                              _ snapshot: [DownloadTask],
                              _ env: ReducerEnv) -> ReducerOutput {
        // Seeding never counts as active work — it can run indefinitely.
        let hasActiveWork = snapshot.contains { $0.status.isActiveWork }
        // Must be a transition INTO `.completed`, or an old finished task turns Pause All into shutdown.
        let completedThisTick = snapshot.contains { task in
            task.status == .completed && prev.lastStatuses[task.id] != .completed
        }
        var drainIntent: DrainIntent?
        if env.autoShutdownAction != "none",
           prev.lastHadActiveWork, !hasActiveWork, completedThisTick {
            drainIntent = DrainIntent(action: env.autoShutdownAction)
        }

        // The first snapshot only seeds the baseline, or restored tasks all fire "added".
        var notifications: [AppNotification] = []
        let suppressed = env.notify.onlyWhenInactive && env.isAppActive
        if prev.hasSeenFirstSnapshot, !suppressed {
            for task in snapshot where task.scanVerdict == "flagged" {
                if prev.lastScanVerdicts[task.id] != "flagged" {
                    notifications.append(.scanFlagged(task.name))
                }
            }
            for task in snapshot {
                guard let previous = prev.lastStatuses[task.id] else {
                    if env.notify.onAdded { notifications.append(.added(task.name)) }
                    continue
                }
                guard previous != task.status else { continue }
                switch task.status {
                case .completed:
                    if env.notify.onCompleted { notifications.append(.completed(task.name)) }
                case .failed:
                    if env.notify.onFailed { notifications.append(.failed(task.name)) }
                default:
                    break
                }
            }
        }

        var state = prev
        // Never `Dictionary(uniqueKeysWithValues:)`: it TRAPS on a repeated id, and imports carry those.
        var statuses: [UUID: DownloadStatus] = [:]
        var verdicts: [UUID: String] = [:]
        statuses.reserveCapacity(snapshot.count)
        for task in snapshot {
            statuses[task.id] = task.status
            verdicts[task.id] = task.scanVerdict   // nil removes the key
        }
        state.lastStatuses = statuses
        state.lastScanVerdicts = verdicts
        state.lastHadActiveWork = hasActiveWork
        state.hasSeenFirstSnapshot = true

        return ReducerOutput(notifications: notifications, drainIntent: drainIntent, state: state)
    }
}

public struct ReducerState: Equatable, Sendable {
    public var lastStatuses: [UUID: DownloadStatus]
    public var lastScanVerdicts: [UUID: String]
    public var lastHadActiveWork: Bool
    public var hasSeenFirstSnapshot: Bool

    public init(lastStatuses: [UUID: DownloadStatus] = [:],
                lastScanVerdicts: [UUID: String] = [:],
                lastHadActiveWork: Bool = false,
                hasSeenFirstSnapshot: Bool = false) {
        self.lastStatuses = lastStatuses
        self.lastScanVerdicts = lastScanVerdicts
        self.lastHadActiveWork = lastHadActiveWork
        self.hasSeenFirstSnapshot = hasSeenFirstSnapshot
    }
}

public struct NotifyPrefs: Equatable, Sendable {
    public var onAdded, onCompleted, onFailed, onlyWhenInactive: Bool
    public init(onAdded: Bool, onCompleted: Bool, onFailed: Bool, onlyWhenInactive: Bool) {
        self.onAdded = onAdded; self.onCompleted = onCompleted
        self.onFailed = onFailed; self.onlyWhenInactive = onlyWhenInactive
    }
}

public struct ReducerEnv: Sendable {
    public var notify: NotifyPrefs
    public var isAppActive: Bool
    public var autoShutdownAction: String   // "none" | "quit" | "sleep" | "shutdown"
    public init(notify: NotifyPrefs, isAppActive: Bool, autoShutdownAction: String) {
        self.notify = notify
        self.isAppActive = isAppActive
        self.autoShutdownAction = autoShutdownAction
    }
}

public enum AppNotification: Equatable, Sendable {
    case added(String)
    case completed(String)
    case failed(String)
    case scanFlagged(String)
}

public enum DrainIntent: Equatable, Sendable {
    case quit, sleep, shutdown

    public init?(action: String) {
        switch action {
        case "quit": self = .quit
        case "sleep": self = .sleep
        case "shutdown": self = .shutdown
        default: return nil
        }
    }
}

public struct ReducerOutput: Equatable, Sendable {
    public let notifications: [AppNotification]
    public let drainIntent: DrainIntent?
    public let state: ReducerState

    public init(notifications: [AppNotification], drainIntent: DrainIntent?, state: ReducerState) {
        self.notifications = notifications
        self.drainIntent = drainIntent
        self.state = state
    }
}

public protocol SystemActions: Sendable {
    func post(_ notifications: [AppNotification], sound: Bool)
    func perform(_ intent: DrainIntent)
}
