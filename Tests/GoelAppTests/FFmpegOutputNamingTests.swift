import XCTest
import GoelCore
@testable import GoelApp

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

    func testExistingFileIsNotOverwritten() throws {
        let input = source("talk.mp4")
        let occupied = directory.appendingPathComponent("talk.mkv")
        try Data("existing content".utf8).write(to: occupied)

        let output = FFmpegService.uniqueSibling(of: input, extension: "mkv")
        XCTAssertEqual(output.lastPathComponent, "talk (1).mkv")
        XCTAssertEqual(try Data(contentsOf: occupied), Data("existing content".utf8),
                       "the pre-existing file is untouched")
    }

    func testTwoSourcesWantingTheSameOutputNameGetDifferentFiles() {
        let first = FFmpegService.uniqueSibling(of: source("talk.mp4"), extension: "webm")
        let second = FFmpegService.uniqueSibling(of: source("talk.mkv"), extension: "webm")
        XCTAssertNotEqual(first.path, second.path)
        XCTAssertEqual(first.lastPathComponent, "talk.webm")
        XCTAssertEqual(second.lastPathComponent, "talk (1).webm")
    }

    func testTheClaimedNameExistsOnDiskAndIsEmpty() throws {
        let output = FFmpegService.uniqueSibling(of: source("talk.mp4"), extension: "m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let size = try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber
        XCTAssertEqual(size?.int64Value, 0, "a zero-byte placeholder ffmpeg's -y will overwrite")
    }

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

    func testRepeatedClaimsOnOneSourceStepThroughVariants() {
        let input = source("talk.mp4")
        let names = (0..<3).map { _ in
            FFmpegService.uniqueSibling(of: input, extension: "mkv").lastPathComponent
        }
        XCTAssertEqual(names, ["talk.mkv", "talk (1).mkv", "talk (2).mkv"])
    }

    /// macOS caps a path component at 255 UTF-8 bytes.
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
