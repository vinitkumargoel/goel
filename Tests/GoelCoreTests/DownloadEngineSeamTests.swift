import XCTest
@testable import GoelCore

// MARK: - Capability-introspecting probe engine

/// A controllable ``DownloadEngine`` used to prove the scheduler talks to engines
/// only through the protocol seam — never by downcasting to a concrete type. It
/// advertises whatever capabilities the test asks for, returns a canned
/// ``EngineMetadata`` from `resolveMetadata`, and records the `directory` it was
/// asked to resolve in and the ``EngineConfiguration`` pushed via `configure`.
final class SeamProbeEngine: DownloadEngine, @unchecked Sendable {

    let kind: DownloadKind
    private let caps: EngineCapabilities
    private let metadata: EngineMetadata?

    private let lock = NSLock()
    private var _lastConfiguration: EngineConfiguration?
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
    func setFilePriority(_ priority: FilePriority, fileID: Int, task id: DownloadTask.ID) async {}
    func events(for id: DownloadTask.ID) -> AsyncStream<EngineEvent> { AsyncStream { _ in } }

    func resolveMetadata(for source: DownloadSource, in directory: String) async -> EngineMetadata? {
        lock.lock(); _lastResolveDirectory = directory; lock.unlock()
        return metadata
    }

    func configure(_ configuration: EngineConfiguration) async {
        lock.lock(); _lastConfiguration = configuration; lock.unlock()
    }

    // Inspection

    var lastConfiguration: EngineConfiguration? { lock.lock(); defer { lock.unlock() }; return _lastConfiguration }
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

    // MARK: (d) configure pushes one shared configuration to every engine

    func testConfigurePushesSharedConfigToAllEnginesViaSeam() async {
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

        // Each engine received the configuration via configure(_:), carrying its slice…
        XCTAssertEqual(http.lastConfiguration?.http.timeout, 42)
        XCTAssertEqual(torrent.lastConfiguration?.torrent.encryptionMode, "require")
        XCTAssertEqual(hls.lastConfiguration?.hlsMaxHeight, 720)
        // …and it is the SAME value handed to every engine (built once, no downcasts).
        XCTAssertEqual(http.lastConfiguration, torrent.lastConfiguration)
        XCTAssertEqual(torrent.lastConfiguration, hls.lastConfiguration)
    }
}
