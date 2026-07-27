import XCTest
@testable import GoelCore

/// The save-folder picker's boundary.
///
/// The picker exists so nobody types an absolute server path into the Add dialog,
/// which means the server now *hands out* paths and *creates* directories on
/// request. Both are reachable by anyone holding a session, so the tests that
/// matter are the ones that prove neither can escape the downloads root.
final class SaveFolderBrowserTests: XCTestCase {

    private var root: String = ""
    private var outside: String = ""

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("goel-folders-\(UUID().uuidString)")
        // `outside` is a sibling of `root`, not a child: the point is to have a
        // real directory that exists and is still off-limits.
        root = base.appendingPathComponent("downloads").path
        outside = base.appendingPathComponent("elsewhere").path
        let fm = FileManager.default
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: outside, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(atPath: (root as NSString).deletingLastPathComponent)
    }

    private func mkdir(_ relative: String) throws {
        try FileManager.default.createDirectory(
            atPath: (root as NSString).appendingPathComponent(relative),
            withIntermediateDirectories: true)
    }

    private func touch(_ relative: String) {
        FileManager.default.createFile(
            atPath: (root as NSString).appendingPathComponent(relative), contents: Data())
    }

    // MARK: Listing

    func testRootListingNamesOnlyDirectoriesAndHasNoParent() throws {
        try mkdir("Linux")
        try mkdir("Music")
        touch("notes.txt")

        let listing = try XCTUnwrap(SaveFolderBrowser.listing(of: nil, root: root))
        XCTAssertEqual(listing.folders.map(\.name), ["Linux", "Music"])
        XCTAssertNil(listing.parent, "the root must not offer a way up out of itself")
        XCTAssertEqual(listing.path, listing.root)
    }

    func testHiddenFoldersAreNotOffered() throws {
        try mkdir(".Trash")
        try mkdir("Visible")

        let listing = try XCTUnwrap(SaveFolderBrowser.listing(of: nil, root: root))
        XCTAssertEqual(listing.folders.map(\.name), ["Visible"])
    }

    func testSubfolderListingCanWalkBackUp() throws {
        try mkdir("Linux/ISOs")
        let child = (root as NSString).appendingPathComponent("Linux")

        let listing = try XCTUnwrap(SaveFolderBrowser.listing(of: child, root: root))
        XCTAssertEqual(listing.folders.map(\.name), ["ISOs"])
        XCTAssertEqual(listing.parent, root)
    }

    func testListingRefusesAPathOutsideTheRoot() {
        XCTAssertNil(SaveFolderBrowser.listing(of: outside, root: root))
    }

    func testListingRefusesTraversalOutOfTheRoot() {
        let escape = (root as NSString).appendingPathComponent("../elsewhere")
        XCTAssertNil(SaveFolderBrowser.listing(of: escape, root: root))
    }

    func testListingRefusesAFileAndAMissingFolder() throws {
        touch("notes.txt")
        XCTAssertNil(SaveFolderBrowser.listing(
            of: (root as NSString).appendingPathComponent("notes.txt"), root: root))
        XCTAssertNil(SaveFolderBrowser.listing(
            of: (root as NSString).appendingPathComponent("nope"), root: root))
    }

    func testBlankPathMeansTheRoot() throws {
        let listing = try XCTUnwrap(SaveFolderBrowser.listing(of: "   ", root: root))
        XCTAssertEqual(listing.path, root)
    }

    // MARK: Creating

    func testCreateMakesTheFolderAndReturnsItsPath() throws {
        let made = try XCTUnwrap(SaveFolderBrowser.create(named: "ISOs", in: nil, root: root))
        XCTAssertEqual(made, (root as NSString).appendingPathComponent("ISOs"))
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: made, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testCreatingAFolderThatAlreadyExistsSucceeds() throws {
        try mkdir("ISOs")
        XCTAssertEqual(SaveFolderBrowser.create(named: "ISOs", in: nil, root: root),
                       (root as NSString).appendingPathComponent("ISOs"))
    }

    func testCreateRefusesWhenAFileAlreadyHasTheName() {
        touch("ISOs")
        XCTAssertNil(SaveFolderBrowser.create(named: "ISOs", in: nil, root: root))
    }

    func testCreateRefusesAParentOutsideTheRoot() {
        XCTAssertNil(SaveFolderBrowser.create(named: "ISOs", in: outside, root: root))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: (outside as NSString).appendingPathComponent("ISOs")),
            "nothing may be created outside the downloads folder")
    }

    /// A symlink inside the root that points out of it: the parent passes the
    /// containment check, so only the post-join check catches this.
    func testCreateRefusesThroughASymlinkThatLeavesTheRoot() throws {
        let link = (root as NSString).appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: outside)

        XCTAssertNil(SaveFolderBrowser.create(named: "ISOs", in: link, root: root))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: (outside as NSString).appendingPathComponent("ISOs")))
    }

    // MARK: Name validation

    func testPlainFolderNamesAreAccepted() {
        for name in ["ISOs", "Linux Distros", "2024-releases", "naïve", "a.b"] {
            XCTAssertTrue(RemoteRouter.isPlainFolderName(name), name)
        }
    }

    func testTraversalSlashesHiddenAndEmptyNamesAreRefused() {
        // Not sanitised into something else — refused. Silently creating
        // "download" because someone typed "../" would be its own surprise.
        for name in ["", "   ", ".", "..", "../etc", "a/b", #"a\b"#, ".hidden", "a\nb", "a\0b"] {
            XCTAssertFalse(RemoteRouter.isPlainFolderName(name), name)
        }
    }

    func testAnAbsurdlyLongNameIsRefused() {
        XCTAssertFalse(RemoteRouter.isPlainFolderName(String(repeating: "x", count: 241)))
        XCTAssertTrue(RemoteRouter.isPlainFolderName(String(repeating: "x", count: 240)))
    }
}
