import XCTest
@testable import GoelCore

/// Tier-1 additions: checksum verification, hash parsing, and the file-conflict
/// naming policy.
final class Tier1FeaturesTests: XCTestCase {

    // MARK: Temp helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goel-tier1-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeFile(_ contents: String, named name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }

    // MARK: Checksum digests (known vectors for "abc")

    func testDigestsMatchKnownVectors() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try writeFile("abc", named: "abc.txt", in: dir)

        XCTAssertEqual(try ChecksumVerifier.digest(fileAt: file, algorithm: .md5),
                       "900150983cd24fb0d6963f7d28e17f72")
        XCTAssertEqual(try ChecksumVerifier.digest(fileAt: file, algorithm: .sha1),
                       "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(try ChecksumVerifier.digest(fileAt: file, algorithm: .sha256),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(try ChecksumVerifier.digest(fileAt: file, algorithm: .sha512),
                       "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a" +
                       "2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
    }

    func testVerifyAcceptsMatchAndRejectsMismatch() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try writeFile("abc", named: "abc.txt", in: dir)

        let good = Checksum(algorithm: .sha256,
                            value: "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD")
        let bad = Checksum(algorithm: .sha256, value: String(repeating: "0", count: 64))

        let matched = try await ChecksumVerifier.verify(fileAt: file, expected: good)
        XCTAssertTrue(matched, "Uppercase input should normalize and match")
        let mismatched = try await ChecksumVerifier.verify(fileAt: file, expected: bad)
        XCTAssertFalse(mismatched)
    }

    func testVerifyHandlesMultiChunkFile() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // 3 MiB > the 1 MiB read window, so the streaming path runs many chunks.
        let url = dir.appendingPathComponent("big.bin")
        let blob = Data(repeating: 0x5A, count: 3 * (1 << 20))
        try blob.write(to: url)

        let expectedHex = try ChecksumVerifier.digest(fileAt: url, algorithm: .sha256)
        let ok = try await ChecksumVerifier.verify(
            fileAt: url, expected: Checksum(algorithm: .sha256, value: expectedHex))
        XCTAssertTrue(ok)
    }

    // MARK: Hash parsing / auto-detection

    func testParseAutoDetectsAlgorithmByLength() {
        XCTAssertEqual(Checksum.parse(String(repeating: "a", count: 32))?.algorithm, .md5)
        XCTAssertEqual(Checksum.parse(String(repeating: "a", count: 40))?.algorithm, .sha1)
        XCTAssertEqual(Checksum.parse(String(repeating: "a", count: 64))?.algorithm, .sha256)
        XCTAssertEqual(Checksum.parse(String(repeating: "a", count: 128))?.algorithm, .sha512)
    }

    func testParseNormalizesAndRejectsJunk() {
        XCTAssertEqual(Checksum.parse("  ABCDEF\(String(repeating: "0", count: 58))  ")?.value.count, 64)
        XCTAssertNil(Checksum.parse(""))                                   // empty
        XCTAssertNil(Checksum.parse("xyz123"))                            // non-hex / wrong length
        XCTAssertNil(Checksum.parse(String(repeating: "a", count: 50)))   // valid hex, unknown length
        XCTAssertNil(Checksum.parse("zz" + String(repeating: "a", count: 62))) // non-hex chars
    }

    func testParseWithExplicitAlgorithmEnforcesLength() {
        XCTAssertNotNil(Checksum.parse(String(repeating: "a", count: 64), algorithm: .sha256))
        XCTAssertNil(Checksum.parse(String(repeating: "a", count: 32), algorithm: .sha256))
    }

    // MARK: File-conflict naming policy

    func testResolveNameRenamesAroundExistingFiles() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try writeFile("x", named: "movie.mp4", in: dir)

        let renamed = DownloadManager.resolveName("movie.mp4", in: dir.path, policy: "rename")
        XCTAssertEqual(renamed, "movie (1).mp4")

        // With the first alternate also taken, it advances to (2).
        _ = try writeFile("x", named: "movie (1).mp4", in: dir)
        XCTAssertEqual(DownloadManager.resolveName("movie.mp4", in: dir.path, policy: "rename"),
                       "movie (2).mp4")
    }

    func testResolveNameOverwriteKeepsName() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try writeFile("x", named: "movie.mp4", in: dir)
        XCTAssertEqual(DownloadManager.resolveName("movie.mp4", in: dir.path, policy: "overwrite"),
                       "movie.mp4")
    }

    func testResolveNameNoConflictReturnsBase() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(DownloadManager.resolveName("fresh.bin", in: dir.path, policy: "rename"),
                       "fresh.bin")
    }

    func testResolveNameHandlesExtensionlessNames() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try writeFile("x", named: "README", in: dir)
        XCTAssertEqual(DownloadManager.resolveName("README", in: dir.path, policy: "rename"),
                       "README (1)")
    }

    // MARK: Status / settings plumbing

    func testVerifyingStatusIsActiveNonTerminal() {
        XCTAssertTrue(DownloadStatus.verifying.isActive)
        XCTAssertFalse(DownloadStatus.verifying.isTerminal)
        XCTAssertEqual(DownloadStatus.verifying.displayName, "Verifying")
    }

    func testNewSettingsDefaultsAndBackCompatDecode() throws {
        // Defaults.
        let fresh = AppSettings()
        XCTAssertEqual(fresh.existingFileReaction, "rename")
        XCTAssertFalse(fresh.clipboardMonitorEnabled)

        // An old blob without the new keys still decodes (decodeIfPresent fallbacks).
        let legacy = "{\"selectedProfileName\":\"Medium\"}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: legacy)
        XCTAssertEqual(decoded.existingFileReaction, "rename")
        XCTAssertFalse(decoded.clipboardMonitorEnabled)
    }

    func testExpectedChecksumRoundTripsThroughCodable() throws {
        var task = DownloadTask(source: .url(URL(string: "https://example.test/f.bin")!),
                                name: "f.bin", saveDirectory: "/tmp")
        task.expectedChecksum = Checksum(algorithm: .sha256, value: String(repeating: "a", count: 64))
        let data = try JSONEncoder().encode(task)
        let back = try JSONDecoder().decode(DownloadTask.self, from: data)
        XCTAssertEqual(back.expectedChecksum, task.expectedChecksum)

        // A task encoded without the field decodes with a nil checksum (synthesized
        // Codable uses decodeIfPresent for optionals).
        let plain = DownloadTask(source: .url(URL(string: "https://example.test/g.bin")!),
                                 name: "g.bin", saveDirectory: "/tmp")
        let plainBack = try JSONDecoder().decode(DownloadTask.self,
                                                 from: try JSONEncoder().encode(plain))
        XCTAssertNil(plainBack.expectedChecksum)
    }
}
