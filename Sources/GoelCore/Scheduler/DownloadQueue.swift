import Foundation

/// Optional narrow port over the unified download queue.
///
/// ``DownloadManager`` is the production implementation. Prefer the concrete
/// manager (or ``RemoteBackend`` for the portal) unless a caller needs only
/// lifecycle / observation / basic mutation. Not yet injected at app/daemon
/// call sites — add a typed dependency when a second implementation appears.
///
/// Requirements are `async` so an actor can witness them (same pattern as
/// ``RemoteBackend``).
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

extension DownloadManager: DownloadQueue {
    /// Point-in-time task list. Lives here (rather than on the actor body) because
    /// its witness is the synchronous `snapshot` property; the `async` requirement
    /// is met by the actor hop. `public` so the out-of-module `RemoteBackend`
    /// conformance in `GoelRemoteServer` witnesses the very same method instead of
    /// redeclaring it (it used to, before the portal was split out).
    public func taskSnapshot() async -> [DownloadTask] { snapshot }
}
