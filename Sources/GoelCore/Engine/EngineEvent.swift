import Foundation

/// Live updates an engine emits for a task. The manager applies them to its stored `DownloadTask`
/// and republishes — the UI subscribes to the manager, not the engine.
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

    /// Better on-disk name than the add-time guess (`Content-Disposition`, or extension from
    /// `Content-Type`). Already sanitized/clamped/deconflicted; adopted verbatim so name == file.
    case nameResolved(String)

    /// The engine moved the task to a new status (e.g. downloading -> seeding).
    case statusChanged(DownloadStatus)

    /// Payload fully downloaded. For HTTP this is terminal; for torrents the
    /// manager decides whether to seed.
    case finished

    /// The task failed with a concrete reason.
    case failed(DownloadError)

    /// Fresh resume cursor (HTTP segment offsets + ETag/Last-Modified validators); the manager
    /// persists it into the task's `resumeData` so a download survives relaunches.
    case resumeDataUpdated(Data)

    /// Live snapshot of the task's connections (HTTP segments or torrent peers) for the detail panel.
    /// High-frequency and observational: the manager folds it in without persisting.
    case connectionsUpdated([TaskConnection])

    /// Torrent swarm composition changed (peer/seed counts from the session).
    case swarmUpdated(peers: Int, seeds: Int)

    /// Live per-tracker status for a torrent (announce state + scrape counts).
    /// High-frequency and observational; the manager folds it in without persisting.
    case trackersUpdated([TorrentTracker])

    /// A downsampled piece-availability map for a torrent (fraction downloaded per
    /// bucket, 0…1). Observational; folded in without persisting.
    case piecesUpdated([Double])

    /// The torrent's v1 info-hash (hex), resolved once metadata is known. Works
    /// for `.torrent` files too, unlike parsing a magnet link.
    case infoHashResolved(String)

    /// Real facts about the remote HTTP server (Server header, ETag,
    /// Accept-Ranges, Content-Type) captured from the probe/first response.
    case remoteInfoResolved(RemoteInfo)
}
