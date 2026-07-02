import Foundation

/// The pure fold of a task-list snapshot into user-visible notifications and the
/// one-shot queue-drain intent.
///
/// The app's view model used to run this as two `@MainActor` methods
/// (`emitNotifications` + `checkQueueDrained`) that threaded four mutable fields
/// and were, critically, **order-dependent**: the drain detector had to read the
/// *pre-overwrite* statuses that the notification pass clobbered. That ordering
/// hazard guarded a *destructive* side effect (a system shutdown) and ran only in
/// production, untested.
///
/// Folding both passes into one pure function over an immutable snapshot removes
/// the ordering hazard by construction (both are computed from the same `prev`
/// state) and makes the destructive edge assertable without an actor, `NSApp`, or
/// spawning `/usr/bin/pmset`. The single OS side effect is pushed behind the
/// ``SystemActions`` port.
public enum SnapshotReducer {

    public static func reduce(_ prev: ReducerState,
                              _ snapshot: [DownloadTask],
                              _ env: ReducerEnv) -> ReducerOutput {
        // MARK: Queue-drain edge — reads the PRE-overwrite statuses.
        // Seeding never counts as active work (it can run indefinitely).
        let hasActiveWork = snapshot.contains { task in
            switch task.status {
            case .queued, .requestingMetadata, .downloading, .verifying: return true
            default: return false
            }
        }
        // A task must have transitioned INTO `.completed` on this very tick — an
        // old completed download sitting in the list must not turn a manual
        // "Pause All" into a system shutdown.
        let completedThisTick = snapshot.contains { task in
            task.status == .completed && prev.lastStatuses[task.id] != .completed
        }
        var drainIntent: DrainIntent?
        if env.autoShutdownAction != "none",
           prev.lastHadActiveWork, !hasActiveWork, completedThisTick {
            drainIntent = DrainIntent(action: env.autoShutdownAction)
        }

        // MARK: Notifications — diff against the previous snapshot.
        // The first snapshot only seeds the baseline (so restored tasks never fire
        // "added" at launch); `notifyOnlyWhenInactive` suppresses banners while the
        // app is frontmost. State is still updated in both cases (below).
        var notifications: [AppNotification] = []
        let suppressed = env.notify.onlyWhenInactive && env.isAppActive
        if prev.hasSeenFirstSnapshot, !suppressed {
            // A flagged antivirus verdict warrants a banner regardless of the
            // added/completed/failed preferences — the user enabled scanning.
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

        // MARK: Next state — always refreshed, even when suppressed / first tick.
        var state = prev
        state.lastStatuses = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0.status) })
        state.lastScanVerdicts = Dictionary(uniqueKeysWithValues: snapshot.compactMap { task in
            task.scanVerdict.map { (task.id, $0) }
        })
        state.lastHadActiveWork = hasActiveWork
        state.hasSeenFirstSnapshot = true

        return ReducerOutput(notifications: notifications, drainIntent: drainIntent, state: state)
    }
}

// MARK: - Value types

/// The carry-over state the pump threads across ticks — the four fields the view
/// model used to keep as separate mutable properties, now one round-tripped value.
public struct ReducerState: Equatable, Sendable {
    /// Per-task status from the previous snapshot (added/completed/failed edges).
    public var lastStatuses: [UUID: DownloadStatus]
    /// Per-task antivirus verdicts from the previous snapshot (flag-once).
    public var lastScanVerdicts: [UUID: String]
    /// Whether the previous snapshot had downloads in flight — the drain edge.
    public var lastHadActiveWork: Bool
    /// Whether any snapshot has been seen (the first only seeds the baseline).
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

/// The notification preferences the reducer gates on (mirrors `AppSettings`).
public struct NotifyPrefs: Equatable, Sendable {
    public var onAdded, onCompleted, onFailed, onlyWhenInactive: Bool
    public init(onAdded: Bool, onCompleted: Bool, onFailed: Bool, onlyWhenInactive: Bool) {
        self.onAdded = onAdded; self.onCompleted = onCompleted
        self.onFailed = onFailed; self.onlyWhenInactive = onlyWhenInactive
    }
}

/// The ambient, non-snapshot facts read once per tick.
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

/// A user notification the view model should post. The body carries the task name;
/// the title (a UI string) is supplied by the ``SystemActions`` implementation.
public enum AppNotification: Equatable, Sendable {
    case added(String)
    case completed(String)
    case failed(String)
    case scanFlagged(String)
}

/// The one-shot action taken when the last download finishes.
public enum DrainIntent: Equatable, Sendable {
    case quit, sleep, shutdown

    /// Map the persisted `autoShutdownAction` string; `nil` for "none"/unknown.
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
    /// Non-nil only on the true drain edge — the reducer *decides*, the port *acts*.
    public let drainIntent: DrainIntent?
    public let state: ReducerState

    public init(notifications: [AppNotification], drainIntent: DrainIntent?, state: ReducerState) {
        self.notifications = notifications
        self.drainIntent = drainIntent
        self.state = state
    }
}

// MARK: - The one OS boundary

/// The only side-effecting boundary the pump needs mocked: posting banners and
/// performing the (irreversible) drain action. The *decision* is pure Core; the
/// *effect* is the sole injected thing, so a test can assert the shutdown edge
/// fires without a real `NSApp.terminate` / `pmset` / AppleScript.
public protocol SystemActions: Sendable {
    func post(_ notifications: [AppNotification], sound: Bool)
    func perform(_ intent: DrainIntent)
}
