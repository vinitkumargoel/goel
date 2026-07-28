import Foundation

/// A source's metadata resolved *before* it is committed to the queue — name, size and (torrent)
/// file list for the add-confirmation screen. Never persists a task or occupies a download slot.
public struct DownloadPreview: Sendable, Equatable, Hashable {
    /// The source the preview describes (carried through to the eventual `add`).
    public let source: DownloadSource
    /// Best available display name (Content-Disposition / torrent name / URL).
    public let suggestedName: String
    /// Total size in bytes, or nil when the server/peers didn't report it.
    public let totalBytes: Int64?
    /// True when `totalBytes` is an estimate rather than an exact figure (HLS).
    public let isEstimatedSize: Bool
    /// The files inside the transfer (torrents). Empty for single-file HTTP/HLS.
    public let files: [TransferFile]
    /// Which engine will handle it.
    public let kind: DownloadKind
    /// A non-fatal note explaining a partial/failed resolution (e.g. a magnet
    /// whose metadata didn't arrive in time). The user can still choose to start.
    public let note: String?
    /// A checksum the server published (Digest / Content-MD5 header or a `.sha256` sidecar),
    /// pre-filled but user-visible and editable on the confirmation screen.
    public let suggestedChecksum: Checksum?

    public init(
        source: DownloadSource,
        suggestedName: String,
        totalBytes: Int64?,
        isEstimatedSize: Bool = false,
        files: [TransferFile] = [],
        kind: DownloadKind,
        note: String? = nil,
        suggestedChecksum: Checksum? = nil
    ) {
        self.source = source
        self.suggestedName = suggestedName
        self.totalBytes = totalBytes
        self.isEstimatedSize = isEstimatedSize
        self.files = files
        self.kind = kind
        self.note = note
        self.suggestedChecksum = suggestedChecksum
    }
}
