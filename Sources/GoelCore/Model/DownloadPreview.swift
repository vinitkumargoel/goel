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
