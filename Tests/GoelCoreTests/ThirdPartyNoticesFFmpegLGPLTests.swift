import XCTest

/// LGPL-2.1 §4 needs the licence text *and* a written source offer in THIRD-PARTY-NOTICES.md; trimming it makes the next DMG a violation.
final class ThirdPartyNoticesFFmpegLGPLTests: XCTestCase {
    private func loadNotices() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(contentsOf: repoRoot.appendingPathComponent("THIRD-PARTY-NOTICES.md"),
                          encoding: .utf8)
    }

    func testFFmpegAppearsInBothInventoryTables() throws {
        let notices = try loadNotices()
        XCTAssertTrue(notices.contains("| [FFmpeg](https://ffmpeg.org/) |"),
                      "FFmpeg must be listed in the bundled-component inventory")
        XCTAssertTrue(notices.contains("| FFmpeg | LGPL-2.1-or-later |"),
                      "FFmpeg must be listed in the licence-compatibility table")
    }

    func testLGPLLicenceTextIsReproducedVerbatim() throws {
        let notices = try loadNotices()
        XCTAssertTrue(notices.contains("GNU LESSER GENERAL PUBLIC LICENSE"),
                      "the LGPL-2.1 text itself must be present, not merely linked")
        XCTAssertTrue(notices.contains("Version 2.1, February 1999"),
                      "the reproduced licence must be version 2.1")
        XCTAssertTrue(notices.contains("TERMS AND CONDITIONS FOR COPYING, DISTRIBUTION AND MODIFICATION"),
                      "the operative terms must be reproduced, not just the preamble")
    }

    func testWrittenSourceOfferIsPresentAndReachable() throws {
        let notices = try loadNotices()
        XCTAssertTrue(notices.contains("three years"),
                      "the written offer must state its three-year validity")
        XCTAssertTrue(notices.contains("licensing@vinitk.dev"),
                      "the written offer must name an address the source can be requested from")
    }
}
