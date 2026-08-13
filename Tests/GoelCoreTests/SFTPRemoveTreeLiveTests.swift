import XCTest
@testable import GoelCore

/// Live-server coverage for `SFTPRelay.removeTree`: SFTP's rmdir refuses
/// non-empty directories, so recursive delete is easy to break silently.
/// Gated on `GOEL_LIVE_SFTP=1` (with `GOEL_SFTP_HOST/USER/PASS`) so the
/// suite stays hermetic by default.
final class SFTPRemoveTreeLiveTests: XCTestCase {

    private func liveClient() throws -> SFTPClient {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["GOEL_LIVE_SFTP"] == "1",
                          "set GOEL_LIVE_SFTP=1 with GOEL_SFTP_HOST/USER/PASS to run live SFTP tests")
        guard let host = env["GOEL_SFTP_HOST"], let user = env["GOEL_SFTP_USER"],
              let pass = env["GOEL_SFTP_PASS"] else {
            throw XCTSkip("GOEL_SFTP_HOST/USER/PASS not set")
        }
        let store = HostKeyStore(defaults: UserDefaults(suiteName: "goel.livetest.\(UUID().uuidString)")!)
        let target = SFTPTarget(host: host, username: user, password: pass)
        return SFTPClient(target: target, hostKeys: store)
    }

    /// Trust-on-first-use for the isolated test store, then the client works normally.
    private func trusted(_ client: SFTPClient) async throws -> SFTPClient {
        _ = try await client.probe()
        return client
    }

    func testRemoveTreeDeletesNestedTree() async throws {
        let client = try await trusted(try liveClient())
        let env = ProcessInfo.processInfo.environment
        let base = env["GOEL_SFTP_BASE"] ?? "goel-removetree-test"

        // Build: base/a/b/{one.bin,two.bin}, base/a/empty/, base/top.bin
        try await client.mkdir(base)
        try await client.mkdir("\(base)/a")
        try await client.mkdir("\(base)/a/b")
        try await client.mkdir("\(base)/a/empty")
        let local = FileManager.default.temporaryDirectory
            .appendingPathComponent("goel-removetree-\(UUID().uuidString).bin")
        try Data(repeating: 0x5A, count: 4096).write(to: local)
        defer { try? FileManager.default.removeItem(at: local) }
        for remote in ["\(base)/top.bin", "\(base)/a/b/one.bin", "\(base)/a/b/two.bin"] {
            try await client.upload(localURL: local, remote: remote) { _, _ in }
        }

        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var count = 0
            func bump() { lock.lock(); count += 1; lock.unlock() }
        }
        let ticks = Counter()
        try await SFTPRelay.removeTree(client, path: base,
                                       onProgress: { _, _ in ticks.bump() })

        let parent = (base as NSString).deletingLastPathComponent
        let names = try await client.list(parent.isEmpty ? "." : parent).map(\.name)
        XCTAssertFalse(names.contains((base as NSString).lastPathComponent),
                       "the tree should be gone after removeTree")
        // 3 files + 3 dirs + the root = 7 removals.
        XCTAssertEqual(ticks.count, 7)
    }

    /// Deletes a tree prepared out-of-band (e.g. with symlinks, which the client
    /// cannot create itself): `GOEL_SFTP_PREPARED_PATH=/path/to/tree`.
    func testRemoveTreeDeletesPreparedPath() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let prepared = env["GOEL_SFTP_PREPARED_PATH"], !prepared.isEmpty else {
            throw XCTSkip("GOEL_SFTP_PREPARED_PATH not set")
        }
        let client = try await trusted(try liveClient())
        try await SFTPRelay.removeTree(client, path: prepared)
        let parent = (prepared as NSString).deletingLastPathComponent
        let names = try await client.list(parent.isEmpty ? "." : parent).map(\.name)
        XCTAssertFalse(names.contains((prepared as NSString).lastPathComponent))
    }
}
