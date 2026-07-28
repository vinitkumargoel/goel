import Foundation

public enum EngineEvent: Sendable, Equatable {
    case metadataResolved(name: String, totalBytes: Int64, files: [TransferFile])

    case progress(
        bytesDownloaded: Int64,
        bytesUploaded: Int64,
        downloadSpeed: Double,
        uploadSpeed: Double,
        connectionCount: Int
    )

    case fileProgress(fileID: Int, bytesCompleted: Int64)

    /// Server-supplied: must already be sanitized/clamped/deconflicted, because it is adopted verbatim as the on-disk name.
    case nameResolved(String)

    case statusChanged(DownloadStatus)

    case finished

    case failed(DownloadError)

    case resumeDataUpdated(Data)

    case connectionsUpdated([TaskConnection])

    case swarmUpdated(peers: Int, seeds: Int)

    case trackersUpdated([TorrentTracker])

    case piecesUpdated([Double])

    case infoHashResolved(String)

    case remoteInfoResolved(RemoteInfo)
}
