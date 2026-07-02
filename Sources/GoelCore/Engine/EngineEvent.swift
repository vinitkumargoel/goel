import Foundation

/// Live updates an engine emits for a task. The manager applies these to its
/// stored `DownloadTask` and republishes — the UI subscribes to the manager,
/// not the engine.
public enum EngineEvent: Sendable, Equatable {
    /// Magnet/torrent metadata arrived: name, total size and the file list are
    /// now known. Resolves a `.requestingMetadata` task.
    case metadataResolved(name: String, totalBytes: Int64, files: [TransferFile])

    /// Aggregate progress tick.
    case progress(
        bytesDownloaded: Int64,
        bytesUploaded: Int64,
        downloadSpeed: Double,
        uploadSpeed: Double,
        connectionCount: Int
    )

    /// A single file's completed-byte count changed (multi-file transfers).
    case fileProgress(fileID: Int, bytesCompleted: Int64)

    /// The engine determined a better on-disk name than the one derived at add
    /// time — e.g. from an HTTP `Content-Disposition` header, or by inferring a
    /// missing extension from `Content-Type`. The name is already sanitized,
    /// length-clamped and conflict-resolved by the engine; the manager adopts it
    /// verbatim (so the displayed name and the file on disk never diverge).
    case nameResolved(String)

    /// The engine moved the task to a new status (e.g. downloading -> seeding).
    case statusChanged(DownloadStatus)

    /// Payload fully downloaded. For HTTP this is terminal; for torrents the
    /// manager decides whether to seed.
    case finished

    /// The task failed with a concrete reason.
    case failed(DownloadError)

    /// The engine produced a fresh resume cursor (HTTP segment offsets +
    /// ETag/Last-Modified validators). The manager persists this into the
    /// task's `resumeData` so a download can continue across relaunches.
    case resumeDataUpdated(Data)

    /// A live snapshot of the task's transfer connections — HTTP segments or
    /// torrent peers — for the detail panel. High-frequency and observational:
    /// the manager folds it into the task without persisting.
    case connectionsUpdated([TaskConnection])

    /// Torrent swarm composition changed (peer/seed counts from the session).
    case swarmUpdated(peers: Int, seeds: Int)

    /// Real facts about the remote HTTP server (Server header, ETag,
    /// Accept-Ranges, Content-Type) captured from the probe/first response.
    case remoteInfoResolved(RemoteInfo)
}
