import Foundation

/// A ``DownloadEngine`` placeholder for a source kind the current build was
/// compiled *without* — e.g. BitTorrent on the iOS App Store build, which
/// excludes the `GoelTorrent` product (and hence libtorrent).
///
/// It still claims its `kind` so the scheduler's `engine(for:)` routing always
/// has an engine to hand a task to, but every `add` fails the task immediately
/// with a clear "not available in this build" error instead of silently leaving
/// it stranded in the queue. Pause/resume/remove are no-ops and it advertises no
/// capabilities. The desktop/daemon composition root replaces it by injecting the
/// real engine (see ``DownloadManager``'s `makeTorrentEngine`).
public final class UnavailableEngine: DownloadEngine {
    public let kind: DownloadKind
    private let hub = EventHub()
    private let reason: String

    public init(kind: DownloadKind, reason: String? = nil) {
        self.kind = kind
        self.reason = reason ?? "This download type isn’t supported in this build."
    }

    public func add(_ task: DownloadTask) async {
        // Safe against a missed event: the scheduler subscribes to `events(for:)`
        // *before* calling `add`, so this failure doublet is always delivered.
        hub.fail(task.id, .unknown(reason))
    }

    public func pause(_ id: DownloadTask.ID) async {}
    public func resume(_ id: DownloadTask.ID) async {}
    public func remove(_ id: DownloadTask.ID, deleteData: Bool) async {}
    public func applyLimits(_ profile: TrafficProfile) async {}

    public func events(for id: DownloadTask.ID) -> AsyncStream<EngineEvent> {
        hub.subscribe(id)
    }
}
