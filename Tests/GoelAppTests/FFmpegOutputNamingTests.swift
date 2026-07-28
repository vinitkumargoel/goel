import XCTest
import GoelCore
@testable import GoelApp

/// How a conversion picks the file it writes — the one part of ``FFmpegService`` testable without
/// ffmpeg, and the part that can destroy a file: an exists-check tells two concurrent jobs "no".
final class FFmpegOutputNamingTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ffmpeg-naming-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func source(_ name: String) -> URL {
        let url = directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        return url
    }

    func testFirstChoiceIsTheSiblingName() {
        let output = FFmpegService.uniqueSibling(of: source("talk.mp4"), extension: "mkv")
        XCTAssertEqual(output.lastPathComponent, "talk.mkv")
        XCTAssertEqual(output.deletingLastPathComponent().path, directory.path,
                       "the output lands beside the source, never anywhere else")
    }

    /// Never clobber: an existing file with the wanted name pushes the conversion
    /// onto a numbered variant instead of overwriting it.
    func testExistingFileIsNotOverwritten() throws {
        let input = source("talk.mp4")
        let occupied = directory.appendingPathComponent("talk.mkv")
        try Data("existing content".utf8).write(to: occupied)

        let output = FFmpegService.uniqueSibling(of: input, extension: "mkv")
        XCTAssertEqual(output.lastPathComponent, "talk (1).mkv")
        XCTAssertEqual(try Data(contentsOf: occupied), Data("existing content".utf8),
                       "the pre-existing file is untouched")
    }

    /// Why the name is claimed with `O_EXCL` rather than merely tested: `talk.mp4` and `talk.mkv`
    /// both convert to `talk.webm`, and an exists-check hands the same path to both concurrent jobs.
    func testTwoSourcesWantingTheSameOutputNameGetDifferentFiles() {
        let first = FFmpegService.uniqueSibling(of: source("talk.mp4"), extension: "webm")
        let second = FFmpegService.uniqueSibling(of: source("talk.mkv"), extension: "webm")
        XCTAssertNotEqual(first.path, second.path)
        XCTAssertEqual(first.lastPathComponent, "talk.webm")
        XCTAssertEqual(second.lastPathComponent, "talk (1).webm")
    }

    /// The claim has to be visible on disk immediately — that is what makes it a
    /// claim rather than an intention.
    func testTheClaimedNameExistsOnDiskAndIsEmpty() throws {
        let output = FFmpegService.uniqueSibling(of: source("talk.mp4"), extension: "m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let size = try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber
        XCTAssertEqual(size?.int64Value, 0, "a zero-byte placeholder ffmpeg's -y will overwrite")
    }

    /// Many simultaneous claims from different threads must produce that many
    /// distinct files — this is the race the O_EXCL loop exists to lose safely.
    func testConcurrentClaimsNeverCollide() {
        let inputs = (0..<24).map { source("clip\($0).mp4") }
        let lock = NSLock()
        var claimed: [String] = []
        DispatchQueue.concurrentPerform(iterations: inputs.count) { index in
            let output = FFmpegService.uniqueSibling(of: inputs[index], extension: "out")
            lock.lock()
            claimed.append(output.path)
            lock.unlock()
        }
        XCTAssertEqual(Set(claimed).count, inputs.count, "every claim is unique")
    }

    /// Same *source*, claimed repeatedly: each claim must step to a fresh name
    /// rather than handing back the one already taken.
    func testRepeatedClaimsOnOneSourceStepThroughVariants() {
        let input = source("talk.mp4")
        let names = (0..<3).map { _ in
            FFmpegService.uniqueSibling(of: input, extension: "mkv").lastPathComponent
        }
        XCTAssertEqual(names, ["talk.mkv", "talk (1).mkv", "talk (2).mkv"])
    }

    /// A CDN-length filename must not produce a name the filesystem rejects
    /// outright (macOS caps a component at 255 UTF-8 bytes).
    func testAbsurdlyLongNamesAreClamped() {
        let long = String(repeating: "a", count: 400) + ".mp4"
        let output = FFmpegService.uniqueSibling(of: source(long), extension: "mp3")
        XCTAssertLessThanOrEqual(output.lastPathComponent.utf8.count, 255)
        XCTAssertTrue(output.lastPathComponent.hasSuffix(".mp3"),
                      "clamping must not cost the extension — the file has to stay openable")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path),
                      "the clamped name is one the filesystem actually accepted")
    }
}
