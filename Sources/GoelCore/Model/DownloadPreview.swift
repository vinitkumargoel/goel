import Foundation

public struct DownloadPreview: Sendable, Equatable, Hashable {
    public let source: DownloadSource
    public let suggestedName: String
    public let totalBytes: Int64?
    public let isEstimatedSize: Bool
    public let files: [TransferFile]
    public let kind: DownloadKind
    public let note: String?
    public let suggestedChecksum: Checksum?
    /// True when ``note`` is the engine's generic "couldn't reach the server" line rather than a
    /// specific reason, so the UI can phrase it itself instead of matching English text.
    public let noteIsGenericUnreachable: Bool

    public init(
        source: DownloadSource,
        suggestedName: String,
        totalBytes: Int64?,
        isEstimatedSize: Bool = false,
        files: [TransferFile] = [],
        kind: DownloadKind,
        note: String? = nil,
        suggestedChecksum: Checksum? = nil,
        noteIsGenericUnreachable: Bool = false
    ) {
        self.source = source
        self.suggestedName = suggestedName
        self.totalBytes = totalBytes
        self.isEstimatedSize = isEstimatedSize
        self.files = files
        self.kind = kind
        self.note = note
        self.suggestedChecksum = suggestedChecksum
        self.noteIsGenericUnreachable = noteIsGenericUnreachable
    }
}
