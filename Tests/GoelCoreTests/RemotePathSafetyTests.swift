import XCTest
@testable import GoelCore

/// The validator standing between an untrusted destination string and a real write on someone else's filesystem (see `RemotePathSafety`).
final class RemotePathSafetyTests: XCTestCase {

    private func rejection(_ result: Result<String, RemotePathSafety.Rejection>) -> RemotePathSafety.Rejection? {
        if case .failure(let e) = result { return e }
        return nil
    }

    private func value(_ result: Result<String, RemotePathSafety.Rejection>) -> String? {
        if case .success(let v) = result { return v }
        return nil
    }

    // MARK: Directories

    func testAbsolutePathIsAccepted() {
        XCTAssertEqual(value(RemotePathSafety.validateDirectory("/srv/media")), "/srv/media")
    }

    func testDotMeansLoginHome() {
        XCTAssertEqual(value(RemotePathSafety.validateDirectory(".")), ".")
    }

    func testTrailingSlashIsNormalisedAway() {
        XCTAssertEqual(value(RemotePathSafety.validateDirectory("/srv/media/")), "/srv/media")
    }

    /// The whole point of the validator: `..` anywhere places the file outside the folder the user picked.
    func testTraversalIsRejectedAnywhereInThePath() {
        for path in ["/srv/../etc", "/../etc", "/srv/media/..", "/a/b/../../../root"] {
            XCTAssertEqual(rejection(RemotePathSafety.validateDirectory(path)), .traversal, path)
        }
    }

    func testRelativePathWithoutDotIsRejected() {
        XCTAssertEqual(rejection(RemotePathSafety.validateDirectory("srv/media")), .notAbsolute)
    }

    /// An empty destination must not silently become the login home — that is a file landing somewhere nobody chose.
    func testEmptyAndWhitespaceAreRejected() {
        XCTAssertEqual(rejection(RemotePathSafety.validateDirectory("")), .empty)
        XCTAssertEqual(rejection(RemotePathSafety.validateDirectory("   ")), .empty)
    }

    func testInteriorDoubleSlashIsRejected() {
        XCTAssertEqual(rejection(RemotePathSafety.validateDirectory("/srv//media")), .emptyComponent)
    }

    func testControlCharactersAreRejected() {
        XCTAssertEqual(rejection(RemotePathSafety.validateDirectory("/srv/me\ndia")), .controlCharacter)
        XCTAssertEqual(rejection(RemotePathSafety.validateDirectory("/srv/me\u{0}dia")), .controlCharacter)
    }

    func testOverlongPathIsRejected() {
        let deep = "/" + String(repeating: "a", count: RemotePathSafety.maxPathBytes + 10)
        XCTAssertEqual(rejection(RemotePathSafety.validateDirectory(deep)), .pathTooLong)
    }

    func testOverlongComponentIsRejected() {
        let name = String(repeating: "b", count: RemotePathSafety.maxNameBytes + 1)
        XCTAssertEqual(rejection(RemotePathSafety.validateDirectory("/srv/\(name)")), .nameTooLong)
    }

    // MARK: File names

    func testEmbeddedPathCollapsesToASingleComponent() {
        XCTAssertEqual(RemotePathSafety.sanitizedComponent("../../etc/passwd"), "passwd")
        XCTAssertEqual(RemotePathSafety.sanitizedComponent("/etc/shadow"), "shadow")
    }

    func testControlCharactersAreStrippedFromNames() {
        XCTAssertEqual(RemotePathSafety.sanitizedComponent("re\nport.pdf"), "report.pdf")
    }

    /// A leading "-" makes the file look like a flag to any command-line tool run on the server later.
    func testLeadingDashIsRemoved() {
        XCTAssertEqual(RemotePathSafety.sanitizedComponent("--rf.txt"), "rf.txt")
    }

    func testNamesWithNothingUsableAreRejected() {
        XCTAssertNil(RemotePathSafety.sanitizedComponent(""))
        XCTAssertNil(RemotePathSafety.sanitizedComponent("."))
        XCTAssertNil(RemotePathSafety.sanitizedComponent(".."))
        XCTAssertNil(RemotePathSafety.sanitizedComponent("---"))
    }

    /// Legal on Linux and merely awkward — rewriting them would rename the user's file for no safety gain.
    func testAwkwardButLegalCharactersSurvive() {
        XCTAssertEqual(RemotePathSafety.sanitizedComponent("a:b?c*d.txt"), "a:b?c*d.txt")
    }

    /// macOS hands out NFD; the server stores NFC. Without this a conflict check compares two spellings of one name.
    func testNamesAreNormalisedToNFC() {
        let decomposed = "cafe\u{0301}.txt"                 // e + combining acute
        XCTAssertEqual(RemotePathSafety.sanitizedComponent(decomposed), "café.txt")
    }

    func testLongNameIsClampedWithRoomForTheTemporarySuffix() {
        let long = String(repeating: "x", count: 400) + ".mkv"
        let clamped = RemotePathSafety.sanitizedComponent(long)!
        XCTAssertTrue(clamped.hasSuffix(".mkv"))
        let temporary = RemotePathSafety.temporaryName(for: clamped, token: "deadbeef")
        XCTAssertLessThanOrEqual(temporary.utf8.count, RemotePathSafety.maxNameBytes)
    }

    // MARK: Nested paths

    func testNestedPathKeepsItsStructure() {
        XCTAssertEqual(value(RemotePathSafety.validateRelativePath("season 1/ep01.mkv")), "season 1/ep01.mkv")
    }

    /// Engine-declared torrent and HLS paths are attacker-influenced in exactly this shape, so every component is checked, not just the leaf.
    func testTraversalInAnyNestedComponentIsRejected() {
        for path in ["../evil", "a/../../evil", "a/b/../../../evil"] {
            XCTAssertEqual(rejection(RemotePathSafety.validateRelativePath(path)), .traversal, path)
        }
    }

    func testAbsoluteNestedPathIsRejected() {
        XCTAssertEqual(rejection(RemotePathSafety.validateRelativePath("/etc/passwd")), .traversal)
    }

    func testNestedComponentsAreSanitisedIndividually() {
        XCTAssertEqual(value(RemotePathSafety.validateRelativePath("-flags/-report.pdf")), "flags/report.pdf")
    }

    /// A control character in a *path* is refused rather than stripped: a path is structural, so quietly rewriting it would change where the file lands. In a bare name it is stripped instead.
    func testControlCharacterInANestedPathIsRefusedNotRewritten() {
        XCTAssertEqual(rejection(RemotePathSafety.validateRelativePath("a/re\nport.pdf")), .controlCharacter)
        XCTAssertEqual(RemotePathSafety.sanitizedComponent("re\nport.pdf"), "report.pdf")
    }

    // MARK: Joining and containment

    func testJoinAgainstHomeOmitsTheLeadingDot() {
        XCTAssertEqual(value(RemotePathSafety.join(directory: ".", relative: "a.txt")), "a.txt")
    }

    func testJoinProducesExactlyOneSeparator() {
        XCTAssertEqual(value(RemotePathSafety.join(directory: "/srv", relative: "a.txt")), "/srv/a.txt")
        XCTAssertEqual(value(RemotePathSafety.join(directory: "/srv/", relative: "a.txt")), "/srv/a.txt")
    }

    /// Guards the symlink case: the server says where a destination really lands, and the answer has to still be inside what the user picked.
    func testContainmentRejectsAResolvedPathOutsideTheChosenRoot() {
        XCTAssertTrue(RemotePathSafety.isContained("/srv/media", within: "/srv/media"))
        XCTAssertTrue(RemotePathSafety.isContained("/srv/media/sub", within: "/srv/media"))
        XCTAssertFalse(RemotePathSafety.isContained("/etc", within: "/srv/media"))
        XCTAssertFalse(RemotePathSafety.isContained("/srv/media-other", within: "/srv/media"))
    }

    func testTemporaryNameIsDistinctPerToken() {
        let a = RemotePathSafety.temporaryName(for: "film.mkv", token: "aaaaaaaa")
        let b = RemotePathSafety.temporaryName(for: "film.mkv", token: "bbbbbbbb")
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasSuffix(".part"))
    }
}
