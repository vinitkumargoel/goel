import Foundation

public struct TaskConnection: Codable, Sendable, Equatable, Hashable, Identifiable {
    public var id: String

    public var label: String

    public var detail: String

    public var downloadSpeed: Double   // bytes/sec
    public var uploadSpeed: Double     // bytes/sec

    public var progress: Double

    /// Optional for backward-compatible decode of older snapshots.
    public var adapterId: String?

    public var adapterLabel: String?

    public init(id: String, label: String, detail: String,
                downloadSpeed: Double = 0, uploadSpeed: Double = 0,
                progress: Double = 0,
                adapterId: String? = nil,
                adapterLabel: String? = nil) {
        self.id = id
        self.label = label
        self.detail = detail
        self.downloadSpeed = downloadSpeed
        self.uploadSpeed = uploadSpeed
        self.progress = progress
        self.adapterId = adapterId
        self.adapterLabel = adapterLabel
    }
}

public struct RemoteInfo: Codable, Sendable, Equatable, Hashable {
    public var server: String?

    public var etag: String?

    public var acceptRanges: Bool?

    public var mimeType: String?

    public init(server: String? = nil, etag: String? = nil,
                acceptRanges: Bool? = nil, mimeType: String? = nil) {
        self.server = server
        self.etag = etag
        self.acceptRanges = acceptRanges
        self.mimeType = mimeType
    }
}
