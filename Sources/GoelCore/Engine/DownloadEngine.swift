import Foundation

/// The seam between the scheduler and a concrete transfer backend.
///
/// Both the real HTTP engine and the (currently mock) torrent engine conform to
/// this. A production libtorrent shim slots in behind the same protocol without
/// the scheduler or UI changing.
public protocol DownloadEngine: AnyObject, Sendable {
    /// Which kind of source this engine handles.
    var kind: DownloadKind { get }

    /// Whether this engine can take a given source.
    func canHandle(_ source: DownloadSource) -> Bool

    /// Begin (or register) a task. Emits events via `events(for:)`.
    func add(_ task: DownloadTask) async

    /// Pause an in-flight task, preserving resume state.
    func pause(_ id: DownloadTask.ID) async

    /// Resume a paused task.
    func resume(_ id: DownloadTask.ID) async

    /// Remove a task, optionally deleting downloaded data from disk.
    func remove(_ id: DownloadTask.ID, deleteData: Bool) async

    /// Apply the active traffic profile's bandwidth and connection caps.
    func applyLimits(_ profile: TrafficProfile) async

    /// Per-file selection / priority changed for a task.
    func setFilePriority(_ priority: FilePriority, fileID: Int, task: DownloadTask.ID) async

    /// Switch a task between sequential (in-order) and rarest-first download.
    /// Meaningful for torrents; other engines ignore it.
    func setSequential(_ sequential: Bool, task: DownloadTask.ID) async

    /// Re-verify a torrent's on-disk data against its piece hashes. Torrent-only.
    func forceRecheck(_ id: DownloadTask.ID) async

    /// Force an immediate re-announce to a torrent's trackers. Torrent-only.
    func forceReannounce(_ id: DownloadTask.ID) async

    /// Cap a task's upload rate in bytes/sec (nil/0 = uncapped). Torrent-only.
    func setUploadLimit(_ bytesPerSec: Int64?, task: DownloadTask.ID) async

    /// Stop seeding a torrent once its share ratio reaches `ratio` (nil = no
    /// per-task limit). Torrent-only.
    func setSeedRatioLimit(_ ratio: Double?, task: DownloadTask.ID) async

    /// The live event stream for a task. Multiple subscribers are supported.
    func events(for id: DownloadTask.ID) -> AsyncStream<EngineEvent>

    /// Which optional capabilities this engine advertises. Lets the scheduler ask
    /// *what an engine can do* instead of downcasting to a concrete engine type.
    nonisolated var capabilities: EngineCapabilities { get }

    /// Resolve a source's metadata for the add-confirmation preview, **without**
    /// starting a tracked download. Returns nil when the engine can't resolve it
    /// (timeout / no peers answered / the engine doesn't probe at all).
    func resolveMetadata(for source: DownloadSource, in directory: String) async -> EngineMetadata?

    /// Apply the engine-agnostic configuration. Each engine consumes only the
    /// slice it cares about (HTTP network knobs / torrent session knobs / HLS
    /// height) and ignores the rest.
    func configure(_ configuration: EngineConfiguration) async
}

public extension DownloadEngine {
    func canHandle(_ source: DownloadSource) -> Bool {
        source.kind == kind
    }

    /// Default: no optional capabilities. An engine opts in by overriding this.
    nonisolated var capabilities: EngineCapabilities { [] }

    /// Default: the engine doesn't resolve metadata ahead of a download.
    func resolveMetadata(for source: DownloadSource, in directory: String) async -> EngineMetadata? { nil }

    /// Default: the engine has nothing to configure.
    func configure(_ configuration: EngineConfiguration) async {}

    /// Default: download order isn't controllable (non-torrent engines).
    func setSequential(_ sequential: Bool, task: DownloadTask.ID) async {}

    /// Defaults: the maintenance / seeding controls below are torrent-only, so
    /// every other engine inherits a no-op.
    func forceRecheck(_ id: DownloadTask.ID) async {}
    func forceReannounce(_ id: DownloadTask.ID) async {}
    func setUploadLimit(_ bytesPerSec: Int64?, task: DownloadTask.ID) async {}
    func setSeedRatioLimit(_ ratio: Double?, task: DownloadTask.ID) async {}
}

// MARK: - Capability description

/// The optional capabilities a ``DownloadEngine`` may advertise, so the scheduler
/// can route work uniformly without knowing the concrete engine type.
public struct EngineCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The engine can resolve a source's metadata ahead of a download
    /// (``DownloadEngine/resolveMetadata(for:in:)``).
    public static let resolvesMetadata = EngineCapabilities(rawValue: 1 << 0)
    /// The engine honours per-file selection / priority within a multi-file task.
    public static let perFilePriority = EngineCapabilities(rawValue: 1 << 1)
    /// The engine emits resume data so a paused transfer can continue mid-stream.
    public static let producesResumeData = EngineCapabilities(rawValue: 1 << 2)
}

// MARK: - Metadata preview

/// A source's resolved metadata, gathered for the add-confirmation preview before
/// anything is committed to the queue. An empty `name` means the engine has no
/// better name than the caller's own default (the manager folds in its fallback).
public struct EngineMetadata: Sendable {
    /// Best display name the engine could resolve, or empty when it has none.
    public var name: String
    /// Total size in bytes, or nil when unknown / not reported.
    public var totalBytes: Int64?
    /// The files inside the transfer (torrents). Empty for single-file transfers.
    public var files: [TransferFile]
    /// True when `totalBytes` is an estimate rather than an exact figure (HLS).
    public var isEstimatedSize: Bool
    /// Whether the source was reachable. False flags a probe that failed but may
    /// still succeed once the download actually starts.
    public var reachable: Bool
    /// An integrity hash the server itself published (a `Digest`/`Content-MD5`
    /// header or a `.sha256` sidecar file), offered as the pre-filled checksum on
    /// the add-confirmation screen. Never trusted silently — the user sees it.
    public var suggestedChecksum: Checksum?

    public init(
        name: String,
        totalBytes: Int64?,
        files: [TransferFile] = [],
        isEstimatedSize: Bool = false,
        reachable: Bool = true,
        suggestedChecksum: Checksum? = nil
    ) {
        self.name = name
        self.totalBytes = totalBytes
        self.files = files
        self.isEstimatedSize = isEstimatedSize
        self.reachable = reachable
        self.suggestedChecksum = suggestedChecksum
    }
}

// MARK: - Engine configuration

/// The engine-agnostic configuration the scheduler pushes down through
/// ``DownloadEngine/configure(_:)``. It bundles every engine's settings slice so
/// the manager builds it once and hands the same value to each engine, which
/// picks out only what it understands. `Equatable` because all of its members are.
public struct EngineConfiguration: Sendable, Equatable {
    /// HTTP network-layer settings (timeout / proxy / User-Agent / cookies / retry).
    public var http: HTTPNetworkConfig
    /// libtorrent session settings (DHT / LSD / uTP / encryption).
    public var torrent: TorrentEngine.SessionConfig
    /// Preferred maximum HLS video height (0 = best available).
    public var hlsMaxHeight: Int

    public init(http: HTTPNetworkConfig, torrent: TorrentEngine.SessionConfig, hlsMaxHeight: Int) {
        self.http = http
        self.torrent = torrent
        self.hlsMaxHeight = hlsMaxHeight
    }
}
