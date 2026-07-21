import Foundation

/// The deep interface for the unified download queue (UI, remote, daemon).
///
/// Callers that only need queue lifecycle, observation, and mutation should
/// depend on this port rather than the concrete ``DownloadManager`` surface
/// (settings, engines, export, …). ``DownloadManager`` is the production
/// implementation; pure cores such as ``AutomationCore`` and
/// ``SchedulingPolicy`` sit underneath it.
///
/// Requirements are `async` so an actor can witness them (same pattern as
/// ``RemoteBackend``). Concrete sync helpers on ``DownloadManager``
/// (`updates()`, `add(...)` with defaults, non-async `task(_:)`) stay on the
/// concrete type for ergonomic app call sites.
public protocol DownloadQueue: AnyObject, Sendable {
    // MARK: Lifecycle

    /// Restore queue + settings from the on-disk store (if any). Call once
    /// after construction, before adding work.
    func restore() async

    /// Cancel live subscriptions, observers, and side-effect services.
    func shutdown() async

    // MARK: Observe

    /// Point-in-time task list.
    func taskSnapshot() async -> [DownloadTask]

    // MARK: Mutate

    func pause(_ id: DownloadTask.ID) async
    func resume(_ id: DownloadTask.ID) async
    func retry(_ id: DownloadTask.ID) async
    func remove(_ id: DownloadTask.ID, deleteData: Bool) async
    func pauseAll() async
    func resumeAll() async
}

extension DownloadManager: DownloadQueue {}
