import XCTest
import GoelCore
@testable import GoelApp

/// The ffmpeg path is a settings field that names a binary the app will execute. A bad value must be
/// refused *and reported* — silently falling back to the bundled copy would hide the rejection.
final class FFmpegOverrideTests: XCTestCase {

    private func reason(_ override: String) -> String? {
        FFmpegService.unavailableReason(override: override)
    }

    func testARelativePathIsRefusedAndSaysWhy() throws {
        let message = try XCTUnwrap(reason("ffmpeg"))
        XCTAssertTrue(message.contains("isn’t a full path"), message)
        XCTAssertFalse(FFmpegService.isAvailable(override: "ffmpeg"))
        XCTAssertNil(FFmpegService.executable(override: "ffmpeg"),
                     "a rejected override must not fall through to the bundled copy")
    }

    func testAPathToNothingIsRefusedAndSaysWhy() throws {
        let message = try XCTUnwrap(reason("/nonexistent/volume/xyz123/ffmpeg"))
        XCTAssertTrue(message.contains("There’s no file at the ffmpeg path"), message)
    }

    func testAScriptInterpreterIsRefusedByName() throws {
        let interpreter = try XCTUnwrap(
            ProcessSafety.interpreterBlocklist.first { FileManager.default.fileExists(atPath: $0) },
            "no blocklisted interpreter exists on this machine to test against")
        let message = try XCTUnwrap(reason(interpreter))
        XCTAssertTrue(message.contains("script interpreter"), message)
        XCTAssertFalse(FFmpegService.isAvailable(override: interpreter),
                       "\(interpreter) would turn Convert into arbitrary code execution")
    }

    func testADirectoryIsNotAProgram() throws {
        let message = try XCTUnwrap(reason("/tmp"))
        XCTAssertTrue(message.contains("isn’t a program"), message)
    }

    func testAnOverrideIsTrimmedBeforeItIsJudged() {
        XCTAssertEqual(reason("   "), reason(""),
                       "whitespace is an empty field, not a relative path")
    }

    func testEveryRejectionTellsTheUserHowToRecover() {
        for bad in ["ffmpeg", "/nonexistent/volume/xyz123/ffmpeg", "/tmp"] {
            let message = reason(bad) ?? ""
            XCTAssertTrue(message.contains("Clear the field") || message.contains("clear the field"),
                          "‘\(bad)’ rejection leaves the user stuck: \(message)")
        }
    }

    func testARejectionQuotesThePathSoTheUserCanSeeTheTypo() throws {
        let message = try XCTUnwrap(reason("/nonexistent/volume/xyz123/ffmpeg"))
        XCTAssertTrue(message.contains("/nonexistent/volume/xyz123/ffmpeg"), message)
    }
}
