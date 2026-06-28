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
}
