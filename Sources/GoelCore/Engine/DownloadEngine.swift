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

    /// The live event stream for a task. Multiple subscribers are supported.
    func events(for id: DownloadTask.ID) -> AsyncStream<EngineEvent>

    /// Which optional capabilities this engine advertises. Lets the scheduler ask
    /// *what an engine can do* instead of downcasting to a concrete engine type.
    nonisolated var capabilities: EngineCapabilities { get }

    /// Resolve a source's metadata for the add-confirmation preview, **without**
    /// starting a tracked download. Returns nil when the engine can't resolve it
    /// (timeout / no peers answered / the engine doesn't probe at all).
    func resolveMetadata(for source: DownloadSource, in directory: String) async -> EngineMetadata?
}

public extension DownloadEngine {
    func canHandle(_ source: DownloadSource) -> Bool {
        source.kind == kind
    }

    /// Default: no optional capabilities. An engine opts in by overriding this.
    nonisolated var capabilities: EngineCapabilities { [] }

    /// Default: the engine doesn't resolve metadata ahead of a download.
    func resolveMetadata(for source: DownloadSource, in directory: String) async -> EngineMetadata? { nil }
}

// MARK: - Capability-scoped refinements

/// Optional engine behaviours, expressed as refinement protocols that pair with
/// the ``EngineCapabilities`` flags. The scheduler reaches an optional behaviour
/// through an intentional `as?` capability query (e.g. `engine as? FilePrioritizing`)
/// instead of every engine carrying a no-op it doesn't mean. Only the engines that
/// actually implement a behaviour conform to its refinement.

/// Engines that honour per-file selection / priority within a multi-file task.
public protocol FilePrioritizing: DownloadEngine {
    func setFilePriority(_ priority: FilePriority, fileID: Int, task: DownloadTask.ID) async
}

/// Torrent engines: piece-order control plus the libtorrent session knobs. Refines
/// ``FilePrioritizing`` because a torrent engine also honours per-file priority.
protocol TorrentControlling: FilePrioritizing {
    /// Switch a task between sequential (in-order, streamable) and rarest-first.
    func setSequential(_ sequential: Bool, task: DownloadTask.ID) async
    /// Apply the session-level BitTorrent settings (DHT / PeX / LPD / uTP / encryption).
    func configure(_ session: TorrentSessionConfig) async
    /// Re-verify a torrent's on-disk data against its piece hashes.
    func forceRecheck(_ id: DownloadTask.ID) async
    /// Force an immediate re-announce to a torrent's trackers.
    func forceReannounce(_ id: DownloadTask.ID) async
    /// Cap a task's upload rate in bytes/sec (nil/0 = uncapped).
    func setUploadLimit(_ bytesPerSec: Int64?, task: DownloadTask.ID) async
    /// Stop seeding once the share ratio reaches `ratio` (nil = no per-task limit).
    func setSeedRatioLimit(_ ratio: Double?, task: DownloadTask.ID) async
}

/// The HTTP engine's network-configuration seam (timeout / proxy / UA / cookies /
/// retry). Refines ``FilePrioritizing`` — the HTTP engine also carries per-file
/// selection for multi-file (metalink) transfers.
protocol HTTPConfigurable: FilePrioritizing {
    func configure(_ net: HTTPNetworkConfig) async
    /// Multi-path adapter set for network aggregation. Default no-op for mocks.
    func configureAggregation(_ config: AggregationEngineConfig) async
}

extension HTTPConfigurable {
    func configureAggregation(_ config: AggregationEngineConfig) async {}
}

/// The HLS engine's preferred-rendition-height seam.
protocol HLSConfigurable: DownloadEngine {
    func configure(maxHeight: Int) async
}

// MARK: - Torrent session configuration

/// The session-level BitTorrent settings the scheduler pushes to a torrent engine.
/// A free-standing value type (promoted out of the concrete engines) so the shared
/// configuration seam never names a specific engine. `Equatable` for testability.
public struct TorrentSessionConfig: Sendable, Equatable {
    /// Wire encryption policy: `prefer` | `require` | `disable`.
    public var encryptionMode: String
    /// Distributed Hash Table peer discovery.
    public var enableDHT: Bool
    /// Peer Exchange.
    public var enablePeX: Bool
    /// Local Peer Discovery.
    public var enableLPD: Bool
    /// uTP (Micro Transport Protocol) transport.
    public var enableUTP: Bool
    /// The user's proxy choice, applied to the HTTP fetch of a remote `.torrent`
    /// file body so it follows the same proxy policy as real downloads (the
    /// torrent swarm itself is separate). Defaults to "follow the OS proxy".
    public var proxy: NetworkGuard.ProxySpec

    public init(
        encryptionMode: String = "prefer",
        enableDHT: Bool = true,
        enablePeX: Bool = true,
        enableLPD: Bool = true,
        enableUTP: Bool = true,
        proxy: NetworkGuard.ProxySpec = NetworkGuard.ProxySpec()
    ) {
        self.encryptionMode = encryptionMode
        self.enableDHT = enableDHT
        self.enablePeX = enablePeX
        self.enableLPD = enableLPD
        self.enableUTP = enableUTP
        self.proxy = proxy
    }
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

