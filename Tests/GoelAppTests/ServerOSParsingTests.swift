import XCTest
@testable import GoelApp

/// `/etc/os-release` comes off a machine we do not control and is rendered in the sidebar.
final class ServerOSParsingTests: XCTestCase {

    func testAnOrdinaryUbuntuReleaseFileIsRead() throws {
        let os = try XCTUnwrap(ServerOS.parse(osRelease: """
            NAME="Ubuntu"
            VERSION="22.04.3 LTS (Jammy Jellyfish)"
            ID=ubuntu
            PRETTY_NAME="Ubuntu 22.04.3 LTS"
            """))
        XCTAssertEqual(os.id, "ubuntu")
        XCTAssertEqual(os.pretty, "Ubuntu 22.04.3 LTS")
    }

    func testPrettyNameWinsOverNameAndNameIsTheFallback() throws {
        let withBoth = try XCTUnwrap(ServerOS.parse(osRelease: """
            NAME="Alpine Linux"
            PRETTY_NAME="Alpine Linux v3.19"
            ID=alpine
            """))
        XCTAssertEqual(withBoth.pretty, "Alpine Linux v3.19")

        let nameOnly = try XCTUnwrap(ServerOS.parse(osRelease: """
            NAME="Alpine Linux"
            ID=alpine
            """))
        XCTAssertEqual(nameOnly.pretty, "Alpine Linux")
    }

    func testIDIsLowercasedSoTheTintLookupMatches() throws {
        let os = try XCTUnwrap(ServerOS.parse(osRelease: "ID=Debian\nPRETTY_NAME=\"Debian 12\""))
        XCTAssertEqual(os.id, "debian")
    }

    func testAReleaseWithOnlyAPrettyNameDerivesAnID() throws {
        let os = try XCTUnwrap(ServerOS.parse(osRelease: "PRETTY_NAME=\"Rocky Linux 9\""))
        XCTAssertEqual(os.pretty, "Rocky Linux 9")
        XCTAssertEqual(os.id, "rocky linux 9", "the id is derived so the row still renders")
    }

    func testAReleaseWithOnlyAnIDCapitalisesItForDisplay() throws {
        let os = try XCTUnwrap(ServerOS.parse(osRelease: "ID=fedora"))
        XCTAssertEqual(os.id, "fedora")
        XCTAssertEqual(os.pretty, "Fedora")
    }

    func testCommentsBlankLinesAndValuelessLinesAreSkipped() throws {
        let os = try XCTUnwrap(ServerOS.parse(osRelease: """
            # this is a comment
            ID=arch

            NOT_A_PAIR
            PRETTY_NAME='Arch Linux'
            """))
        XCTAssertEqual(os.id, "arch")
        XCTAssertEqual(os.pretty, "Arch Linux", "single quotes are stripped too")
    }

    func testATruncatedValueLosesItsOpeningQuoteRatherThanKeepingIt() throws {
        let os = try XCTUnwrap(ServerOS.parse(osRelease: "ID=debian\nPRETTY_NAME=\"Debian 12"))
        XCTAssertEqual(os.pretty, "Debian 12",
                       "a missing closing quote must not leave a stray quote in the sidebar")
    }

    func testAnAbsurdlyLongValueIsCappedBeforeItReachesTheUI() throws {
        let os = try XCTUnwrap(ServerOS.parse(
            osRelease: "ID=evil\nPRETTY_NAME=\(String(repeating: "A", count: 5000))"))
        XCTAssertEqual(os.pretty.count, 200,
                       "a hostile server must not be able to stretch the sidebar without limit")
    }

    func testNothingUsableYieldsNoServerOS() {
        XCTAssertNil(ServerOS.parse(osRelease: ""))
        XCTAssertNil(ServerOS.parse(osRelease: "# only a comment"))
        XCTAssertNil(ServerOS.parse(osRelease: "VERSION_ID=\"12\"\nHOME_URL=\"https://e.test\""))
    }
}
