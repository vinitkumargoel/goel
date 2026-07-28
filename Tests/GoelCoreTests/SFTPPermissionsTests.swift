import XCTest
@testable import GoelCore

final class SFTPPermissionsTests: XCTestCase {

    func testRendersTheCommonModesAsLsWouldWriteThem() {
        XCTAssertEqual(SFTPPermissions.string(for: 0o644), "rw-r--r--")
        XCTAssertEqual(SFTPPermissions.string(for: 0o755), "rwxr-xr-x")
        XCTAssertEqual(SFTPPermissions.string(for: 0o600), "rw-------")
        XCTAssertEqual(SFTPPermissions.string(for: 0o777), "rwxrwxrwx")
        XCTAssertEqual(SFTPPermissions.string(for: 0), "---------")
    }

    func testSpecialBitsReplaceTheExecuteColumn() {
        // Lowercase means execute is also set; uppercase means setuid does nothing.
        XCTAssertEqual(SFTPPermissions.string(for: 0o4755), "rwsr-xr-x")
        XCTAssertEqual(SFTPPermissions.string(for: 0o4644), "rwSr--r--")
        XCTAssertEqual(SFTPPermissions.string(for: 0o2755), "rwxr-sr-x")
        XCTAssertEqual(SFTPPermissions.string(for: 0o2745), "rwxr-Sr-x")
        XCTAssertEqual(SFTPPermissions.string(for: 0o1777), "rwxrwxrwt")
        XCTAssertEqual(SFTPPermissions.string(for: 0o1666), "rw-rw-rwT")
    }

    func testFileTypeBitsAboveTheModeAreIgnored() {
        // S_IFDIR | 0755 — what a raw st_mode carries.
        XCTAssertEqual(SFTPPermissions.string(for: 0o040755), "rwxr-xr-x")
    }

    func testParsesThreeAndFourDigitOctal() {
        XCTAssertEqual(SFTPPermissions.parse(octal: "644"), 0o644)
        XCTAssertEqual(SFTPPermissions.parse(octal: "0644"), 0o644)
        XCTAssertEqual(SFTPPermissions.parse(octal: "4755"), 0o4755)
        XCTAssertEqual(SFTPPermissions.parse(octal: "  755 "), 0o755)
    }

    func testRejectsAnythingThatIsNotAMode() {
        // Each of these would otherwise be silently accepted as some *other* valid mode.
        for bad in ["", "6", "64", "65444", "abc", "0x644", "648", "-644", "6 4 4", "٦٤٤"] {
            XCTAssertNil(SFTPPermissions.parse(octal: bad), "should reject “\(bad)”")
        }
    }

    func testSettingABitLeavesTheOthersAlone() {
        XCTAssertEqual(SFTPPermissions.setting(0o644, bit: 0o100, on: true), 0o744)
        XCTAssertEqual(SFTPPermissions.setting(0o744, bit: 0o100, on: false), 0o644)
        XCTAssertEqual(SFTPPermissions.setting(0o644, bit: 0o400, on: true), 0o644)
    }

    func testAttributesExposeModeSeparatelyFromTheRawStMode() {
        let attributes = SFTPAttributes(exists: true, isDirectory: true, isSymlink: false,
                                        size: 4096, modified: nil, permissions: 0o040755,
                                        ownerID: 501, groupID: 20)
        XCTAssertEqual(attributes.mode, 0o755)
        XCTAssertEqual(attributes.octalString, "0755")
        XCTAssertEqual(attributes.modeString, "rwxr-xr-x")
    }

    func testVolumeSpaceReportsUsageWithoutDividingByZero() {
        let space = SFTPVolumeSpace(totalBytes: 1_000, freeBytes: 250)
        XCTAssertEqual(space.usedBytes, 750)
        XCTAssertEqual(space.usedFraction ?? 0, 0.75, accuracy: 0.0001)

        XCTAssertNil(SFTPVolumeSpace(totalBytes: 0, freeBytes: 0).usedFraction)

        // `f_bavail` excludes the root reserve, so free can exceed total; used must not go negative.
        XCTAssertEqual(SFTPVolumeSpace(totalBytes: 100, freeBytes: 150).usedBytes, 0)
    }
}
