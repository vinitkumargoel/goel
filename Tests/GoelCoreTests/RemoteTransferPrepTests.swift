import XCTest
@testable import GoelCore

/// `openForResume` decides how much of a partial download to keep. Two ways of guessing "0" used to
/// reach `truncate(atOffset: 0)` and delete a multi-gigabyte partial with no error anywhere: a stat
/// that failed collapsing to size 0, and a nil `remoteSize` ("the server didn't say") being compared
/// as if it were 0. These tests pin both, plus the case that must still truncate.
final class RemoteTransferPrepTests: XCTestCase {

    private var tempDirs: [URL] = []

    override func tearDownWithError() throws {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir) }
        tempDirs.removeAll()
    }

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goel-resume-prep-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    /// The bytes already on disk, treated as the thing the fix exists to protect.
    private static let partial = Data(repeating: 0xAB, count: 4096)

    private func writePartial(in dir: URL, named name: String = "movie.mkv") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Self.partial.write(to: url)
        return url
    }

    func testOpenForResumeThrowsWhenTheLocalSizeCannotBeReadInsteadOfResumingFromZero() throws {
        let dir = makeTempDir()
        // `blocker` is a regular file, so anything under it is ENOTDIR: the path can neither be created
        // nor stat'd. That is the shape of every "stat didn't answer" case the guard covers (external
        // volume, ACL re-check, TOCTOU) — and it is the only one reproducible without a real network mount.
        let blocker = dir.appendingPathComponent("blocker")
        try Data("not a directory".utf8).write(to: blocker)
        let savePath = blocker.appendingPathComponent("movie.mkv").path

        XCTAssertThrowsError(
            try RemoteTransferPrep.openForResume(saveDirectory: dir.path, savePath: savePath,
                                                 remoteSize: 10_000_000_000)
        ) { error in
            // The distinguishing signal: the fix refuses *at the stat*, naming the size it could not read.
            // Before the fix the missing size silently became 0 and the call ran on to open the file,
            // which is why the failure surfaced as `.fileMissing` — after truncating anything it did open.
            guard case DownloadError.unknown(let message) = error else {
                return XCTFail("expected the stat failure to be reported, got \(error) — a stat that collapses to size 0 truncates the partial")
            }
            XCTAssertTrue(message.contains("how much of it is already downloaded"),
                          "the failure must say the size could not be read, not something incidental: \(message)")
        }
    }

    func testOpenForResumeKeepsThePartialWhenTheServerDidNotReportASize() throws {
        let dir = makeTempDir()
        let url = try writePartial(in: dir)

        // nil means "the server didn't say", never zero. Judging 4 KiB of downloaded bytes against an
        // unknown remote size is exactly the comparison that threw the partial away.
        let opened = try RemoteTransferPrep.openForResume(saveDirectory: dir.path,
                                                          savePath: url.path,
                                                          remoteSize: nil)
        try opened.handle.close()

        XCTAssertEqual(opened.resumeFrom, Int64(Self.partial.count),
                       "an unknown remote size restarted the transfer from 0 instead of resuming")
        XCTAssertEqual(try Data(contentsOf: url), Self.partial,
                       "the partial download was truncated because the server did not send a size")
    }

    func testOpenForResumeTruncatesWhenTheRemoteFileIsSmallerThanTheLocalPartial() throws {
        let dir = makeTempDir()
        let url = try writePartial(in: dir)

        // Guards the fix against over-correcting: a local file longer than the remote one cannot be a
        // prefix of it, so resuming would append onto bytes that do not belong to this file.
        let opened = try RemoteTransferPrep.openForResume(saveDirectory: dir.path,
                                                          savePath: url.path,
                                                          remoteSize: 512)
        try opened.handle.close()

        XCTAssertEqual(opened.resumeFrom, 0,
                       "a local file larger than the remote one must restart, not resume past the end of the real file")
        XCTAssertEqual(try Data(contentsOf: url), Data(),
                       "the stale over-long partial was left on disk and the new bytes were appended to it")
    }

    func testOpenForResumeKeepsThePartialWhenTheRemoteFileIsLarger() throws {
        let dir = makeTempDir()
        let url = try writePartial(in: dir)

        // The ordinary resume path — kept alongside the truncating case so a future "just always
        // truncate" simplification fails loudly instead of silently re-downloading everything.
        let opened = try RemoteTransferPrep.openForResume(saveDirectory: dir.path,
                                                          savePath: url.path,
                                                          remoteSize: Int64(Self.partial.count) * 4)
        try opened.handle.close()

        XCTAssertEqual(opened.resumeFrom, Int64(Self.partial.count))
        XCTAssertEqual(try Data(contentsOf: url), Self.partial,
                       "a normal resume discarded the bytes it was supposed to continue from")
    }
}
