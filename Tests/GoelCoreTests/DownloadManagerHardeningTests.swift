import XCTest
@testable import GoelCore

/// Regression cover for the hardening fixes in `DownloadManager.swift`:
/// the untrusted-backup import deny-list, and the batched pause/resume paths.
final class DownloadManagerHardeningTests: XCTestCase {

    private let saveDir = NSTemporaryDirectory()

    // MARK: Import sanitisation

    /// A hostile "backup" must not be able to point the app at a proxy it chose,
    /// install portal credentials it knows, widen the portal's reverse-proxy
    /// trust, or move where downloads and the audit record land. Every one of
    /// these was adopted verbatim before, defeating ``importEnvelope(_:)``'s own
    /// documented guarantee.
    func testImportedSettingsNeverAdoptProxyPortalOrDirectoryFields() {
        var hostile = AppSettings()
        hostile.proxyMode = "manual"
        hostile.proxyType = "http"
        hostile.proxyHost = "mitm.attacker.example"
        hostile.proxyPort = 8080
        hostile.proxyAllProtocols = true
        hostile.remoteRequireAuth = false
        hostile.remoteUsername = "attacker"
        hostile.remotePasswordHash = "known-hash"
        hostile.remoteReadOnly = false
        hostile.remoteTLSEnabled = false
        hostile.remoteTLSIdentityPath = "/tmp/evil.p12"
        hostile.remoteLoginMaxAttempts = 9_999
        hostile.remoteLoginBackoffSeconds = 0
        hostile.remoteSessionMinutes = 100_000
        hostile.remoteTrustedHeaderAuthEnabled = true
        hostile.remoteTrustedHeaderName = "X-Forwarded-User"
        hostile.remoteTrustedProxies = ["0.0.0.0/0"]
        hostile.defaultSaveDirectory = "/tmp/attacker-drop"
        hostile.auditLogDirectory = "/tmp/attacker-audit"
        hostile.theme = "dark"   // benign field — must still be adopted

        var current = AppSettings()
        current.defaultSaveDirectory = saveDir
        current.remoteUsername = "owner"
        current.remotePasswordHash = "owner-hash"

        let safe = DownloadManager.sanitizedImportedSettings(hostile, current: current)

        XCTAssertEqual(safe.proxyMode, current.proxyMode)
        XCTAssertEqual(safe.proxyType, current.proxyType)
        XCTAssertEqual(safe.proxyHost, current.proxyHost)
        XCTAssertEqual(safe.proxyPort, current.proxyPort)
        XCTAssertEqual(safe.proxyAllProtocols, current.proxyAllProtocols)

        XCTAssertEqual(safe.remoteRequireAuth, current.remoteRequireAuth)
        XCTAssertEqual(safe.remoteUsername, "owner")
        XCTAssertEqual(safe.remotePasswordHash, "owner-hash")
        XCTAssertEqual(safe.remoteReadOnly, current.remoteReadOnly)
        XCTAssertEqual(safe.remoteTLSEnabled, current.remoteTLSEnabled)
        XCTAssertEqual(safe.remoteTLSIdentityPath, current.remoteTLSIdentityPath)
        XCTAssertEqual(safe.remoteLoginMaxAttempts, current.remoteLoginMaxAttempts)
        XCTAssertEqual(safe.remoteLoginBackoffSeconds, current.remoteLoginBackoffSeconds)
        XCTAssertEqual(safe.remoteSessionMinutes, current.remoteSessionMinutes)
        XCTAssertEqual(safe.remoteTrustedHeaderAuthEnabled, current.remoteTrustedHeaderAuthEnabled)
        XCTAssertEqual(safe.remoteTrustedHeaderName, current.remoteTrustedHeaderName)
        XCTAssertEqual(safe.remoteTrustedProxies, current.remoteTrustedProxies)

        XCTAssertEqual(safe.defaultSaveDirectory, saveDir)
        XCTAssertEqual(safe.auditLogDirectory, current.auditLogDirectory)

        XCTAssertEqual(safe.theme, "dark")
    }

    // MARK: Batched pause / resume

    /// ``pauseAll()``/``resumeAll()`` now coalesce their snapshot and scheduler
    /// passes instead of running one per task. The observable behaviour must be
    /// unchanged: every eligible task ends up paused, the engine is told exactly
    /// once per running task, and a following ``resumeAll()`` re-fills the slots.
    func testPauseAllThenResumeAllCoversEveryTaskExactlyOnce() async throws {
        let http = FakeEngine(kind: .http)
        let profile = TrafficProfile(
            name: "Test",
            maxDownloadBytesPerSec: 5 * 1024 * 1024,
            maxUploadBytesPerSec: 1 * 1024 * 1024,
            maxConnections: 100,
            maxConnectionsPerServer: 8,
            maxSimultaneousDownloads: 2,
            maxMetadataResolutions: 99,
            seedRatioLimit: 1.0,
            enableExtraConnections: true
        )
        let manager = DownloadManager(
            httpEngine: http,
            torrentEngine: FakeEngine(kind: .torrent),
            settings: AppSettings(
                profiles: [profile] + TrafficProfile.defaults,
                selectedProfileName: profile.name,
                defaultSaveDirectory: saveDir
            ),
            store: nil
        )
        defer { Task { await manager.shutdown() } }

        for i in 0..<6 {
            await manager.add(source: .url(URL(string: "https://example.com/f\(i).bin")!))
        }
        // Let the scheduler hand the first two tasks to the engine.
        try await pollUntil { await http.added.count == 2 }

        await manager.pauseAll()
        let paused = await manager.snapshot
        XCTAssertEqual(paused.count, 6)
        XCTAssertTrue(paused.allSatisfy { $0.status == .paused },
                      "pauseAll must pause every queued and active task")
        XCTAssertEqual(http.paused.count, 2,
                       "only the engine-started tasks are paused at the engine, once each")
        XCTAssertEqual(Set(http.paused).count, 2)

        await manager.resumeAll()
        // Exactly the cap goes back to the engine; the rest wait in `.queued`.
        try await pollUntil { await http.resumed.count == 2 }
        let resumed = await manager.snapshot
        XCTAssertTrue(resumed.allSatisfy { $0.status != .paused },
                      "resumeAll must leave nothing paused")
        XCTAssertEqual(resumed.filter { $0.status == .queued }.count, 4)
    }

    /// Poll an async predicate until it holds or the deadline passes.
    private func pollUntil(
        timeout: TimeInterval = 2,
        _ predicate: @Sendable () async -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }
}
