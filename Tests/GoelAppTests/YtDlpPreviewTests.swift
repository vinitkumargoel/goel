import XCTest
import GoelCore
@testable import GoelApp

/// yt-dlp hands back a title straight from the page, so the preview is where an attacker-chosen
/// string becomes a filename.
final class YtDlpPreviewTests: XCTestCase {

    private func resolved(title: String = "Talk",
                          url: String = "https://cdn.example.test/v.mp4",
                          ext: String? = nil) -> YtDlpResolver.Resolved {
        YtDlpResolver.Resolved(title: title,
                               mediaURL: URL(string: url)!,
                               fileExtension: ext)
    }

    func testAProgressiveStreamKeepsItsDeclaredExtension() throws {
        let preview = try XCTUnwrap(YtDlpResolver.preview(for: resolved(ext: "webm")))
        XCTAssertEqual(preview.suggestedName, "Talk.webm")
        XCTAssertEqual(preview.kind, .http)
        XCTAssertFalse(preview.isEstimatedSize)
    }

    func testAnUndeclaredExtensionFallsBackToBinRatherThanNothing() throws {
        let preview = try XCTUnwrap(YtDlpResolver.preview(for: resolved()))
        XCTAssertEqual(preview.suggestedName, "Talk.bin")
    }

    func testAnHLSStreamIsNamedMP4AndItsSizeIsMarkedAnEstimate() throws {
        let preview = try XCTUnwrap(YtDlpResolver.preview(
            for: resolved(url: "https://cdn.example.test/index.m3u8")))
        XCTAssertEqual(preview.kind, .hls)
        XCTAssertEqual(preview.suggestedName, "Talk.mp4")
        XCTAssertTrue(preview.isEstimatedSize,
                      "a playlist has no Content-Length — the size shown is a guess")
        XCTAssertNil(preview.totalBytes)
    }

    func testATitleCannotEscapeTheSaveDirectory() throws {
        let preview = try XCTUnwrap(YtDlpResolver.preview(
            for: resolved(title: "../../../../etc/cron.d/evil", ext: "mp4")))
        XCTAssertFalse(preview.suggestedName.contains(".."), preview.suggestedName)
        XCTAssertFalse(preview.suggestedName.contains("/"), preview.suggestedName)
    }

    func testATitleThatSanitisesAwayCompletelyStillYieldsAUsableName() throws {
        let preview = try XCTUnwrap(YtDlpResolver.preview(for: resolved(title: "", ext: "mp4")))
        XCTAssertFalse(preview.suggestedName.isEmpty)
        XCTAssertTrue(preview.suggestedName.hasSuffix(".mp4"), preview.suggestedName)
    }

    func testAMediaURLOutsideTheSchemeAllowlistYieldsNoPreview() {
        for bad in ["file:///etc/passwd", "javascript:alert(1)", "data:video/mp4;base64,AAAA"] {
            XCTAssertNil(YtDlpResolver.preview(for: resolved(url: bad)),
                         "‘\(bad)’ must not become a download")
        }
    }

    /// ftp:// is a supported transfer kind, not a hole — it must survive and be typed correctly.
    func testAnFTPMediaURLIsAcceptedAndTypedAsFTP() throws {
        let preview = try XCTUnwrap(YtDlpResolver.preview(
            for: resolved(url: "ftp://example.test/v.mp4", ext: "mp4")))
        XCTAssertEqual(preview.kind, .ftp)
    }

    func testThePreviewWarnsThatTheResolvedURLIsPerishable() throws {
        let preview = try XCTUnwrap(YtDlpResolver.preview(for: resolved(ext: "mp4")))
        XCTAssertTrue(preview.note?.contains("expire") ?? false,
                      "a signed CDN URL goes stale — the user has to be told to start soon")
    }
}
