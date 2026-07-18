import Foundation

/// One live transfer connection inside a task — an HTTP segment or a torrent
/// peer — as reported by the engine for the detail panel's Connections and
/// Progress tabs. Purely observational: the UI renders these verbatim and
/// nothing schedules off them.
public struct TaskConnection: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// Stable identity within one task (segment index, or peer "ip:port").
    public var id: String

    /// Primary label — "Segment 3" for HTTP, "185.21.216.4:51413" for a peer.
    public var label: String

    /// Secondary detail — a byte range ("512 MB – 1.0 GB") or a peer's client
    /// ("qBittorrent 4.6.2").
    public var detail: String

    public var downloadSpeed: Double   // bytes/sec
    public var uploadSpeed: Double     // bytes/sec

    /// Fraction of this connection's work completed (segment progress, or the
    /// remote peer's own completeness). 0…1.
    public var progress: Double

    /// Network adapter carrying this connection (multi-path HTTP), e.g. `en0`.
    /// Optional for backward-compatible decode of older snapshots.
    public var adapterId: String?

    /// Display label for the adapter (e.g. `Wi‑Fi`).
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

/// Facts about the remote HTTP server, captured from the probe/first response
/// so the Details tab shows real headers instead of placeholders.
public struct RemoteInfo: Codable, Sendable, Equatable, Hashable {
    /// The `Server` response header, if the server sent one.
    public var server: String?

    /// The entity tag validating resumes, if any.
    public var etag: String?

    /// Whether the server advertised `Accept-Ranges: bytes` (segmentation works).
    public var acceptRanges: Bool?

    /// The `Content-Type` the server reported.
    public var mimeType: String?

    public init(server: String? = nil, etag: String? = nil,
                acceptRanges: Bool? = nil, mimeType: String? = nil) {
        self.server = server
        self.etag = etag
        self.acceptRanges = acceptRanges
        self.mimeType = mimeType
    }
}
