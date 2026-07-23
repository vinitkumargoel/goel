import XCTest
@testable import GoelCore
@testable import GoelTorrent

// MARK: - Capability-introspecting probe engine

/// A controllable engine used to prove the scheduler talks to engines only
/// through the protocol seam — never by downcasting to a concrete type. It
/// advertises whatever capabilities the test asks for, returns a canned
/// ``EngineMetadata`` from `resolveMetadata`, and records the `directory` it was
/// asked to resolve in plus whichever **typed** config slice it received. It
/// conforms to every refinement so one probe can stand in for any engine role.
final class SeamProbeEngine: TorrentControlling, HTTPConfigurable, HLSConfigurable, @unchecked Sendable {

    let kind: DownloadKind
    private let caps: EngineCapabilities
    private let metadata: EngineMetadata?

    private let lock = NSLock()
    private var _lastHTTP: HTTPNetworkConfig?
    private var _lastTorrent: TorrentSessionConfig?
    private var _lastMaxHeight: Int?
    private var _lastResolveDirectory: String?

    init(kind: DownloadKind, capabilities: EngineCapabilities, metadata: EngineMetadata? = nil) {
        self.kind = kind
        self.caps = capabilities
        self.metadata = metadata
    }

    // DownloadEngine

    nonisolated var capabilities: EngineCapabilities { caps }

    func add(_ task: DownloadTask) async {}
    func pause(_ id: DownloadTask.ID) async {}
    func resume(_ id: DownloadTask.ID) async {}
    func remove(_ id: DownloadTask.ID, deleteData: Bool) async {}
    func applyLimits(_ profile: TrafficProfile) async {}
    func events(for id: DownloadTask.ID) -> AsyncStream<EngineEvent> { AsyncStream { _ in } }

    func resolveMetadata(for source: DownloadSource, in directory: String) async -> EngineMetadata? {
        lock.lock(); _lastResolveDirectory = directory; lock.unlock()
        return metadata
    }

    // Refinements — each records only its own typed slice.
    func setFilePriority(_ priority: FilePriority, fileID: Int, task id: DownloadTask.ID) async {}
    func setSequential(_ sequential: Bool, task id: DownloadTask.ID) async {}
    func setUploadLimit(_ bytesPerSec: Int64?, task id: DownloadTask.ID) async {}
    func setSeedRatioLimit(_ ratio: Double?, task id: DownloadTask.ID) async {}
    func forceRecheck(_ id: DownloadTask.ID) async {}
    func forceReannounce(_ id: DownloadTask.ID) async {}
    func configure(_ net: HTTPNetworkConfig) async { lock.lock(); _lastHTTP = net; lock.unlock() }
    func configure(_ session: TorrentSessionConfig) async { lock.lock(); _lastTorrent = session; lock.unlock() }
    func configure(maxHeight: Int) async { lock.lock(); _lastMaxHeight = maxHeight; lock.unlock() }

    // Inspection

    var lastHTTP: HTTPNetworkConfig? { lock.lock(); defer { lock.unlock() }; return _lastHTTP }
    var lastTorrent: TorrentSessionConfig? { lock.lock(); defer { lock.unlock() }; return _lastTorrent }
    var lastMaxHeight: Int? { lock.lock(); defer { lock.unlock() }; return _lastMaxHeight }
    var lastResolveDirectory: String? { lock.lock(); defer { lock.unlock() }; return _lastResolveDirectory }
}

// MARK: - Tests

final class DownloadEngineSeamTests: XCTestCase {

    private let saveDir = NSTemporaryDirectory()

    private func magnet(_ hash: String) -> DownloadSource {
        .magnet("magnet:?xt=urn:btih:\(hash)&dn=Demo+Pack")
    }

    // MARK: (a) Capabilities are advertised correctly

    func testEnginesAdvertiseExpectedCapabilities() {
        XCTAssertEqual(HTTPEngine().capabilities, [.resolvesMetadata, .producesResumeData])
        XCTAssertEqual(TorrentEngine(profile: .high).capabilities, [.resolvesMetadata, .perFilePriority])
        XCTAssertEqual(HLSEngine(profile: .high).capabilities, [])
        XCTAssertEqual(MockTorrentEngine().capabilities, [.resolvesMetadata, .perFilePriority])
        // An engine that doesn't override gets the protocol default: no capabilities.
        XCTAssertEqual(FakeEngine(kind: .http).capabilities, [])
    }

    // MARK: (b) resolveMetadata flows through the seam (no concrete downcast)

    func testResolveMetadataFlowsThroughSeam() async {
        let files = [TransferFile(id: 0, path: "Pack/a.mkv", length: 123)]
        let probe = SeamProbeEngine(
            kind: .torrent,
            capabilities: [.resolvesMetadata, .perFilePriority],
            metadata: EngineMetadata(name: "Resolved Name", totalBytes: 999, files: files))
        let manager = DownloadManager(
            httpEngine: FakeEngine(kind: .http), torrentEngine: probe, store: nil)

        let preview = await manager.resolveMetadata(for: magnet("aaaa"), saveDirectory: saveDir)

        // The engine's metadata is folded straight into the preview…
        XCTAssertEqual(preview.suggestedName, "Resolved Name")
        XCTAssertEqual(preview.totalBytes, 999)
        XCTAssertEqual(preview.files, files)
        XCTAssertEqual(preview.kind, .torrent)
        XCTAssertNil(preview.note)
        // …and the manager threaded the resolved save directory through the seam.
        XCTAssertEqual(probe.lastResolveDirectory, saveDir)
    }

    func testResolveMetadataFoldsFallbackNameWhenEngineReturnsEmpty() async {
        // Engine resolves a size but no name — the manager supplies its own default.
        let probe = SeamProbeEngine(
            kind: .torrent, capabilities: [.resolvesMetadata],
            metadata: EngineMetadata(name: "", totalBytes: 42))
        let manager = DownloadManager(
            httpEngine: FakeEngine(kind: .http), torrentEngine: probe, store: nil)

        let preview = await manager.resolveMetadata(for: magnet("bbbb"), saveDirectory: saveDir)
        XCTAssertEqual(preview.suggestedName, DownloadManager.defaultName(for: magnet("bbbb")))
        XCTAssertEqual(preview.totalBytes, 42)
        XCTAssertNil(preview.note)
    }

    // MARK: (c) Capability gating of the explanatory note

    func testNonResolvingEngineGivesPlainPreviewWithoutNote() async {
        // No `.resolvesMetadata` capability + nil result -> plain best-effort preview.
        let probe = SeamProbeEngine(kind: .torrent, capabilities: [], metadata: nil)
        let manager = DownloadManager(
            httpEngine: FakeEngine(kind: .http), torrentEngine: probe, store: nil)

        let preview = await manager.resolveMetadata(for: magnet("cccc"), saveDirectory: saveDir)
        XCTAssertNil(preview.note, "an engine that doesn't probe must not produce a failure note")
        XCTAssertNil(preview.totalBytes)
        XCTAssertFalse(preview.suggestedName.isEmpty)
    }

    func testResolvingEngineFailureSurfacesNote() async {
        // Advertises resolution but returns nil -> the kind-specific note appears.
        let probe = SeamProbeEngine(kind: .torrent, capabilities: [.resolvesMetadata], metadata: nil)
        let manager = DownloadManager(
            httpEngine: FakeEngine(kind: .http), torrentEngine: probe, store: nil)

        let preview = await manager.resolveMetadata(for: magnet("dddd"), saveDirectory: saveDir)
        XCTAssertNotNil(preview.note, "a probing engine that fails must explain why")
        XCTAssertNil(preview.totalBytes)
    }

    // MARK: (d) each engine configures through its OWN typed seam

    func testEachEngineConfiguresThroughItsOwnTypedSeam() async {
        let http = SeamProbeEngine(kind: .http, capabilities: [.resolvesMetadata, .producesResumeData])
        let torrent = SeamProbeEngine(kind: .torrent, capabilities: [.resolvesMetadata, .perFilePriority])
        let hls = SeamProbeEngine(kind: .hls, capabilities: [])

        var s = AppSettings()
        s.connectionTimeout = 42
        s.hlsMaxHeight = 720
        s.btEncryptionMode = "require"

        let manager = DownloadManager(
            httpEngine: http, torrentEngine: torrent, hlsEngine: hls, settings: s, store: nil)

        await manager.applyEngineConfigs()

        // Each engine received ONLY its own typed slice — no shared union.
        XCTAssertEqual(http.lastHTTP?.timeout, 42)
        XCTAssertEqual(torrent.lastTorrent?.encryptionMode, "require")
        XCTAssertEqual(hls.lastMaxHeight, 720)
        // The HTTP engine never saw a torrent config, and vice-versa.
        XCTAssertNil(http.lastTorrent)
        XCTAssertNil(torrent.lastHTTP)
        XCTAssertNil(hls.lastHTTP)
    }

    // MARK: (e) capability refinements pair with the capability flags

    func testCapabilityRefinementsMatchConformance() {
        let http = HTTPEngine()
        let torrent = TorrentEngine(profile: .high)
        let mock = MockTorrentEngine()
        let hls = HLSEngine(profile: .high)
        let ftp = FTPEngine(profile: .high)
        let sftp = SFTPEngine(profile: .high)

        // Torrent engines advertise .perFilePriority AND conform to the torrent
        // control refinement (which itself refines FilePrioritizing).
        XCTAssertTrue(torrent.capabilities.contains(.perFilePriority))
        XCTAssertTrue(torrent is TorrentControlling)
        XCTAssertTrue(mock.capabilities.contains(.perFilePriority))
        XCTAssertTrue(mock is TorrentControlling)
        // HTTP carries per-file selection (metalink) + its own network config seam,
        // but is not a torrent controller.
        XCTAssertTrue(http is FilePrioritizing)
        XCTAssertTrue(http is HTTPConfigurable)
        XCTAssertFalse(http is TorrentControlling)
        // HLS configures rendition height only — never file priority.
        XCTAssertTrue(hls is HLSConfigurable)
        XCTAssertFalse(hls is FilePrioritizing)
        // FTP / SFTP advertise no optional behaviour and conform to no refinement.
        XCTAssertFalse(ftp is FilePrioritizing)
        XCTAssertFalse(ftp is HLSConfigurable)
        XCTAssertFalse(sftp is FilePrioritizing)
        XCTAssertFalse(sftp is HTTPConfigurable)
    }
}
