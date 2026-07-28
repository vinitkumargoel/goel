import XCTest

/// Guards the LGPL paperwork for the bundled ffmpeg: LGPL-2.1 §4 needs the licence text *and* a source
/// offer in THIRD-PARTY-NOTICES.md; trimming it makes the next DMG a violation nothing else catches.
final class ThirdPartyNoticesFFmpegLGPLTests: XCTestCase {

    /// `<repo>/Tests/GoelCoreTests/<this file>` → `<repo>/THIRD-PARTY-NOTICES.md`.
    private func loadNotices() throws -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GoelCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        return try String(contentsOf: repoRoot.appendingPathComponent("THIRD-PARTY-NOTICES.md"),
                          encoding: .utf8)
    }

    func testFFmpegAppearsInBothInventoryTables() throws {
        let notices = try loadNotices()
        // The component table at the top is the one line 6 says must accompany any
        // redistribution; the compatibility table is what licence reviewers read.
        XCTAssertTrue(notices.contains("| [FFmpeg](https://ffmpeg.org/) |"),
                      "FFmpeg must be listed in the bundled-component inventory")
        XCTAssertTrue(notices.contains("| FFmpeg | LGPL-2.1-or-later |"),
                      "FFmpeg must be listed in the licence-compatibility table")
    }

    func testLGPLLicenceTextIsReproducedVerbatim() throws {
        let notices = try loadNotices()
        // A link to ffmpeg.org is not a copy of the licence. Spot-check the header and
        // the operative section that makes this an LGPL rather than a GPL obligation.
        XCTAssertTrue(notices.contains("GNU LESSER GENERAL PUBLIC LICENSE"),
                      "the LGPL-2.1 text itself must be present, not merely linked")
        XCTAssertTrue(notices.contains("Version 2.1, February 1999"),
                      "the reproduced licence must be version 2.1")
        XCTAssertTrue(notices.contains("TERMS AND CONDITIONS FOR COPYING, DISTRIBUTION AND MODIFICATION"),
                      "the operative terms must be reproduced, not just the preamble")
    }

    func testWrittenSourceOfferIsPresentAndReachable() throws {
        let notices = try loadNotices()
        // The offer is what makes the corresponding source obtainable by someone who got
        // the DMG second-hand. Without a contact address it is worthless.
        XCTAssertTrue(notices.contains("three years"),
                      "the written offer must state its three-year validity")
        XCTAssertTrue(notices.contains("licensing@vinitk.dev"),
                      "the written offer must name an address the source can be requested from")
    }
}
