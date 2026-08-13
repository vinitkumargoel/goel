import XCTest
@testable import GoelCore

/// Live-server proof that byte-offset resume produces byte-identical files in
/// both directions — the property the whole pause/resume feature hangs on.
/// Gated on `GOEL_LIVE_SFTP=1` with `GOEL_SFTP_HOST/USER/PASS`.
final class SFTPResumeLiveTests: XCTestCase {

    private func liveClient() async throws -> SFTPClient {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["GOEL_LIVE_SFTP"] == "1",
                          "set GOEL_LIVE_SFTP=1 with GOEL_SFTP_HOST/USER/PASS to run live SFTP tests")
        guard let host = env["GOEL_SFTP_HOST"], let user = env["GOEL_SFTP_USER"],
              let pass = env["GOEL_SFTP_PASS"] else {
            throw XCTSkip("GOEL_SFTP_HOST/USER/PASS not set")
        }
        let store = HostKeyStore(defaults: UserDefaults(suiteName: "goel.livetest.\(UUID().uuidString)")!)
        let client = SFTPClient(target: SFTPTarget(host: host, username: user, password: pass),
                                hostKeys: store)
        _ = try await client.probe()   // TOFU-pins into the throwaway store
        return client
    }

    private func temp(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    /// Random so a resume that rewound or skipped bytes cannot accidentally match.
    private func randomData(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    func testUploadResumeProducesIdenticalFile() async throws {
        let client = try await liveClient()
        let remote = "goel-resume-up-\(UUID().uuidString).bin"
        let full = randomData(1_000_000)
        let cut = 300_000

        let fullURL = temp("goel-up-full-\(UUID().uuidString).bin")
        let prefixURL = temp("goel-up-prefix-\(UUID().uuidString).bin")
        try full.write(to: fullURL)
        try full.prefix(cut).write(to: prefixURL)
        defer {
            try? FileManager.default.removeItem(at: fullURL)
            try? FileManager.default.removeItem(at: prefixURL)
        }

        // Interrupted upload: the server holds only the first `cut` bytes.
        try await client.upload(localURL: prefixURL, remote: remote) { _, _ in }
        // Resume sends just the tail.
        try await client.upload(localURL: fullURL, remote: remote,
                                resumeFrom: Int64(cut)) { _, _ in }

        let size = try await client.size(remote)
        XCTAssertEqual(size, Int64(full.count))

        let roundTrip = temp("goel-up-check-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: roundTrip) }
        try await client.downloadToFile(remote: remote, localURL: roundTrip) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: roundTrip), full,
                       "resumed upload must be byte-identical, not merely size-identical")

        try await client.remove(remote, isDirectory: false)
    }

    func testDownloadResumeProducesIdenticalFile() async throws {
        let client = try await liveClient()
        let remote = "goel-resume-down-\(UUID().uuidString).bin"
        let full = randomData(1_000_000)
        let cut = 256_000

        let fullURL = temp("goel-down-src-\(UUID().uuidString).bin")
        try full.write(to: fullURL)
        defer { try? FileManager.default.removeItem(at: fullURL) }
        try await client.upload(localURL: fullURL, remote: remote) { _, _ in }

        // Interrupted download: only the first `cut` bytes made it to disk.
        let dest = temp("goel-down-dest-\(UUID().uuidString).bin")
        try full.prefix(cut).write(to: dest)
        defer { try? FileManager.default.removeItem(at: dest) }

        try await client.downloadToFile(remote: remote, localURL: dest,
                                        resumeFrom: Int64(cut)) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: dest), full,
                       "resumed download must be byte-identical, not merely size-identical")

        try await client.remove(remote, isDirectory: false)
    }
}
