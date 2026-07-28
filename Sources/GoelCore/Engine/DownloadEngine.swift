import Foundation

public protocol DownloadEngine: AnyObject, Sendable {
    var kind: DownloadKind { get }

    func canHandle(_ source: DownloadSource) -> Bool

    func add(_ task: DownloadTask) async

    func pause(_ id: DownloadTask.ID) async

    func resume(_ id: DownloadTask.ID) async

    func remove(_ id: DownloadTask.ID, deleteData: Bool) async

    func applyLimits(_ profile: TrafficProfile) async

    func events(for id: DownloadTask.ID) -> AsyncStream<EngineEvent>

    nonisolated var capabilities: EngineCapabilities { get }

    func resolveMetadata(for source: DownloadSource, in directory: String) async -> EngineMetadata?
}

public extension DownloadEngine {
    func canHandle(_ source: DownloadSource) -> Bool {
        source.kind == kind
    }

    nonisolated var capabilities: EngineCapabilities { [] }

    func resolveMetadata(for source: DownloadSource, in directory: String) async -> EngineMetadata? { nil }
}

public protocol FilePrioritizing: DownloadEngine {
    func setFilePriority(_ priority: FilePriority, fileID: Int, task: DownloadTask.ID) async
}

protocol TorrentControlling: FilePrioritizing {
    func setSequential(_ sequential: Bool, task: DownloadTask.ID) async
    func configure(_ session: TorrentSessionConfig) async
    func forceRecheck(_ id: DownloadTask.ID) async
    func forceReannounce(_ id: DownloadTask.ID) async
    func setUploadLimit(_ bytesPerSec: Int64?, task: DownloadTask.ID) async
    func setSeedRatioLimit(_ ratio: Double?, task: DownloadTask.ID) async
}

protocol HTTPConfigurable: FilePrioritizing {
    func configure(_ net: HTTPNetworkConfig) async
    func configureAggregation(_ config: AggregationEngineConfig) async
    func configureFileConflictPolicy(_ policy: String) async
}

extension HTTPConfigurable {
    func configureAggregation(_ config: AggregationEngineConfig) async {}
    func configureFileConflictPolicy(_ policy: String) async {}
}

protocol HLSConfigurable: DownloadEngine {
    func configure(maxHeight: Int) async
}

public struct TorrentSessionConfig: Sendable, Equatable {
    public var encryptionMode: String
    public var enableDHT: Bool
    public var enablePeX: Bool
    public var enableLPD: Bool
    public var enableUTP: Bool
    /// Covers the HTTP fetch of a remote `.torrent` only — the swarm itself is not proxied.
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

public struct EngineCapabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let resolvesMetadata = EngineCapabilities(rawValue: 1 << 0)
    public static let perFilePriority = EngineCapabilities(rawValue: 1 << 1)
    public static let producesResumeData = EngineCapabilities(rawValue: 1 << 2)
}

public struct EngineMetadata: Sendable {
    public var name: String
    public var totalBytes: Int64?
    public var files: [TransferFile]
    public var isEstimatedSize: Bool
    public var reachable: Bool
    /// Server-published hash, shown on the add screen for the user — never applied silently.
    public var suggestedChecksum: Checksum?
    public var failureNote: String?

    public init(
        name: String,
        totalBytes: Int64?,
        files: [TransferFile] = [],
        isEstimatedSize: Bool = false,
        reachable: Bool = true,
        suggestedChecksum: Checksum? = nil,
        failureNote: String? = nil
    ) {
        self.name = name
        self.totalBytes = totalBytes
        self.files = files
        self.isEstimatedSize = isEstimatedSize
        self.reachable = reachable
        self.suggestedChecksum = suggestedChecksum
        self.failureNote = failureNote
    }
}

