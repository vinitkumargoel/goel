import Foundation

/// The seam between the scheduler and a concrete transfer backend.
///
/// Both the real HTTP engine and the (currently mock) torrent engine conform to
/// this. A production libtorrent shim slots in behind the same protocol without
/// the scheduler or UI changing.
public protocol DownloadEngine: AnyObject, Sendable {
    /// Which kind of source this engine handles.
    var kind: DownloadKind { get }

    /// Whether this engine can take a given source.
    func canHandle(_ source: DownloadSource) -> Bool

    /// Begin (or register) a task. Emits events via `events(for:)`.
    func add(_ task: DownloadTask) async

    /// Pause an in-flight task, preserving resume state.
    func pause(_ id: DownloadTask.ID) async

    /// Resume a paused task.
    func resume(_ id: DownloadTask.ID) async

    /// Remove a task, optionally deleting downloaded data from disk.
    func remove(_ id: DownloadTask.ID, deleteData: Bool) async

    /// Apply the active traffic profile's bandwidth and connection caps.
    func applyLimits(_ profile: TrafficProfile) async

    /// Per-file selection / priority changed for a task.
    func setFilePriority(_ priority: FilePriority, fileID: Int, task: DownloadTask.ID) async

    /// The live event stream for a task. Multiple subscribers are supported.
    func events(for id: DownloadTask.ID) -> AsyncStream<EngineEvent>
}

public extension DownloadEngine {
    func canHandle(_ source: DownloadSource) -> Bool {
        source.kind == kind
    }
}
