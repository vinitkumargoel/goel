import XCTest
@testable import GoelCore

/// Filename derivation/safety: length clamping (the NAME_MAX bug), uniqueness,
/// Content-Disposition parsing, MIME→extension inference, and the combined
/// `refinedName` policy. Pure functions, no network.
final class FilenameResolutionTests: XCTestCase {

    // MARK: sanitizedName / clampLength (the "file name is invalid" bug)

    func testSanitizedNameClampsOverlongName() {
        // The opaque-CDN token from the bug report: ~320 chars, no extension.
        let token = String(repeating: "A1b2C3d4", count: 40)   // 320 bytes
        let name = DownloadTask.sanitizedName(token)
        XCTAssertLessThanOrEqual(name.utf8.count, 240, "must clamp under NAME_MAX with headroom")
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.isEmpty)
    }

    func testClampPreservesExtension() {
        let long = String(repeating: "x", count: 400) + ".mp4"
        let clamped = DownloadTask.clampLength(long)
        XCTAssertLessThanOrEqual(clamped.utf8.count, 240)
        XCTAssertEqual((clamped as NSString).pathExtension, "mp4", "extension must survive truncation")
    }

    func testClampLeavesShortNamesUntouched() {
        XCTAssertEqual(DownloadTask.clampLength("video.mp4"), "video.mp4")
    }

    func testClampDoesNotSplitMultibyteCharacters() {
        // 200 emoji (4 bytes each in UTF-8) = 800 bytes -> must clamp on a boundary.
        let emoji = String(repeating: "😀", count: 200) + ".bin"
        let clamped = DownloadTask.clampLength(emoji)
        XCTAssertLessThanOrEqual(clamped.utf8.count, 240)
        XCTAssertNotNil(clamped.data(using: .utf8))   // still valid UTF-8
        XCTAssertEqual((clamped as NSString).pathExtension, "bin")
    }

    // MARK: uniqueName (never-clobber)

    func testUniqueNameAppendsSuffixWhenFileExists() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertEqual(DownloadTask.uniqueName(base: "a.mp4", in: dir.path), "a.mp4",
                       "no conflict -> name unchanged")

        try Data().write(to: dir.appendingPathComponent("a.mp4"))
        XCTAssertEqual(DownloadTask.uniqueName(base: "a.mp4", in: dir.path), "a (1).mp4")

        try Data().write(to: dir.appendingPathComponent("a (1).mp4"))
        XCTAssertEqual(DownloadTask.uniqueName(base: "a.mp4", in: dir.path), "a (2).mp4")
    }

    // MARK: Content-Disposition parsing

    func testContentDispositionPlainFilename() {
        XCTAssertEqual(
            HTTPEngine.filename(fromContentDisposition: "attachment; filename=\"My Video.mp4\""),
            "My Video.mp4")
    }

    func testContentDispositionUnquoted() {
        XCTAssertEqual(
            HTTPEngine.filename(fromContentDisposition: "attachment; filename=report.pdf"),
            "report.pdf")
    }

    func testContentDispositionExtendedFormWins() {
        // RFC 5987 percent-encoded form, with a plain fallback present too.
        let header = "attachment; filename=\"fallback.bin\"; filename*=UTF-8''Caf%C3%A9%20Menu.pdf"
        XCTAssertEqual(HTTPEngine.filename(fromContentDisposition: header), "Café Menu.pdf")
    }

    func testContentDispositionAbsentOrInline() {
        XCTAssertNil(HTTPEngine.filename(fromContentDisposition: nil))
        XCTAssertNil(HTTPEngine.filename(fromContentDisposition: "inline"))
        XCTAssertNil(HTTPEngine.filename(fromContentDisposition: ""))
    }

    // MARK: MIME -> extension

    func testMimeExtensions() {
        XCTAssertEqual(HTTPEngine.fileExtension(forMIME: "video/mp4"), "mp4")
        XCTAssertEqual(HTTPEngine.fileExtension(forMIME: "application/pdf"), "pdf")
        // Parameters after the MIME are ignored.
        XCTAssertEqual(HTTPEngine.fileExtension(forMIME: "video/mp4; codecs=\"avc1\""), "mp4")
        // The generic binary type tells us nothing useful.
        XCTAssertNil(HTTPEngine.fileExtension(forMIME: "application/octet-stream"))
        XCTAssertNil(HTTPEngine.fileExtension(forMIME: nil))
    }

    // MARK: refinedName policy

    func testRefinedNamePrefersContentDisposition() {
        let result = HTTPEngine.refinedName(
            current: "ugly-token",
            suggestedName: "Real Name.mp4",
            contentType: "video/mp4")
        XCTAssertEqual(result, "Real Name.mp4")
    }

    func testRefinedNameInfersExtensionWhenMissing() {
        let result = HTTPEngine.refinedName(
            current: "report",
            suggestedName: nil,
            contentType: "application/pdf")
        XCTAssertEqual(result, "report.pdf")
    }

    func testRefinedNameClampsOverlongUrlNameEvenWithoutHeaders() {
        // The screenshot case with no helpful headers: still must become saveable.
        let token = String(repeating: "Z", count: 400)
        let result = HTTPEngine.refinedName(current: token, suggestedName: nil, contentType: nil)
        XCTAssertNotNil(result, "an unsaveable name must be refined")
        XCTAssertLessThanOrEqual(result!.utf8.count, 240)
    }

    func testRefinedNameReturnsNilWhenAlreadyGood() {
        XCTAssertNil(HTTPEngine.refinedName(
            current: "archive.zip", suggestedName: nil, contentType: "application/octet-stream"))
        // A Content-Disposition that matches the current name is also a no-op.
        XCTAssertNil(HTTPEngine.refinedName(
            current: "archive.zip", suggestedName: "archive.zip", contentType: nil))
    }
}
