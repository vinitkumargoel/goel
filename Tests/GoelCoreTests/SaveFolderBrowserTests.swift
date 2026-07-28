import XCTest
@testable import GoelCore

/// The save-folder picker has no configured root: it goes wherever the server uid goes, so permission bits are the only boundary.
final class SaveFolderBrowserTests: XCTestCase {

    private var base: String = ""
    private var downloads: String = ""
    private var sibling: String = ""

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("goel-folders-\(UUID().uuidString)")
            .path
        downloads = (base as NSString).appendingPathComponent("downloads")
        sibling = (base as NSString).appendingPathComponent("elsewhere")
        let fm = FileManager.default
        try fm.createDirectory(atPath: downloads, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: sibling, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Restore anything chmod'd to unreadable, or the cleanup cannot recurse.
        let fm = FileManager.default
        if let walk = fm.enumerator(atPath: base) {
            for case let name as String in walk {
                try? fm.setAttributes([.posixPermissions: 0o755],
                                      ofItemAtPath: (base as NSString).appendingPathComponent(name))
            }
        }
        try? fm.removeItem(atPath: base)
    }

    private func listing(_ path: String?) -> RemoteFolderListing? {
        SaveFolderBrowser.listing(of: path, defaultFolder: downloads, home: base)
    }

    private func mkdir(_ absolute: String) throws {
        try FileManager.default.createDirectory(atPath: absolute, withIntermediateDirectories: true)
    }

    private func under(_ parent: String, _ name: String) -> String {
        (parent as NSString).appendingPathComponent(name)
    }

    private func chmod(_ path: String, _ bits: Int) throws {
        try FileManager.default.setAttributes([.posixPermissions: bits], ofItemAtPath: path)
    }

    /// Permission bits mean nothing to uid 0, so the tests that turn on them prove nothing when run as root.
    private func skipIfRoot() throws {
        try XCTSkipIf(getuid() == 0, "permission bits do not constrain root")
    }

    func testListingOpensAtTheDefaultFolderWhenGivenNoPath() throws {
        try mkdir(under(downloads, "Linux"))
        let listing = try XCTUnwrap(listing(nil))
        XCTAssertEqual(listing.path, downloads)
        XCTAssertEqual(listing.defaultFolder, downloads)
    }

    func testBlankPathMeansTheDefaultFolder() throws {
        XCTAssertEqual(try XCTUnwrap(listing("   ")).path, downloads)
    }

    func testTheDefaultFolderOffersAWayUp() throws {
        let listing = try XCTUnwrap(listing(nil))
        XCTAssertEqual(listing.parent, base,
                       "the downloads folder is no longer a ceiling")
    }

    func testWalkingUpAndIntoASiblingWorks() throws {
        try mkdir(under(sibling, "Archive"))
        let up = try XCTUnwrap(listing(try XCTUnwrap(listing(nil)).parent))
        XCTAssertTrue(up.folders.map(\.name).contains("elsewhere"))

        let across = try XCTUnwrap(listing(sibling))
        XCTAssertEqual(across.folders.map(\.name), ["Archive"])
    }

    func testOnlyTheFilesystemRootHasNoParent() throws {
        XCTAssertNil(try XCTUnwrap(listing("/")).parent)
        XCTAssertNotNil(try XCTUnwrap(listing(base)).parent)
    }

    func testListingNamesOnlyDirectoriesSorted() throws {
        try mkdir(under(downloads, "Music"))
        try mkdir(under(downloads, "Linux"))
        FileManager.default.createFile(atPath: under(downloads, "notes.txt"), contents: Data())

        XCTAssertEqual(try XCTUnwrap(listing(downloads)).folders.map(\.name), ["Linux", "Music"])
    }

    func testHiddenFoldersAreNotOffered() throws {
        try mkdir(under(downloads, ".Trash"))
        try mkdir(under(downloads, "Visible"))
        XCTAssertEqual(try XCTUnwrap(listing(downloads)).folders.map(\.name), ["Visible"])
    }

    func testListingRefusesAFileAndAMissingFolder() throws {
        FileManager.default.createFile(atPath: under(downloads, "notes.txt"), contents: Data())
        XCTAssertNil(listing(under(downloads, "notes.txt")))
        XCTAssertNil(listing(under(downloads, "nope")))
    }

    func testSymlinksAreResolvedSoTheShownPathIsTheRealOne() throws {
        let link = under(downloads, "shortcut")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: sibling)
        XCTAssertEqual(try XCTUnwrap(listing(link)).path, sibling,
                       "the breadcrumb must name where the write will actually land")
    }

    func testAnUnreadableFolderIsListedButMarkedUnreadable() throws {
        try skipIfRoot()
        let locked = under(downloads, "locked")
        try mkdir(locked)
        try chmod(locked, 0o000)

        let entry = try XCTUnwrap(
            try XCTUnwrap(listing(downloads)).folders.first { $0.name == "locked" })
        XCTAssertFalse(entry.readable)
        XCTAssertFalse(entry.writable)
    }

    func testAReadOnlyFolderIsReadableButNotWritable() throws {
        try skipIfRoot()
        let readOnly = under(downloads, "readonly")
        try mkdir(readOnly)
        try chmod(readOnly, 0o500)

        let entry = try XCTUnwrap(
            try XCTUnwrap(listing(downloads)).folders.first { $0.name == "readonly" })
        XCTAssertTrue(entry.readable)
        XCTAssertFalse(entry.writable)
        XCTAssertFalse(try XCTUnwrap(listing(readOnly)).writable)
    }

    func testCanSaveAnswersForFoldersFilesAndMissingPaths() throws {
        try skipIfRoot()
        XCTAssertTrue(SaveFolderBrowser.canSave(into: downloads))
        XCTAssertFalse(SaveFolderBrowser.canSave(into: under(downloads, "nope")))

        let file = under(downloads, "notes.txt")
        FileManager.default.createFile(atPath: file, contents: Data())
        XCTAssertFalse(SaveFolderBrowser.canSave(into: file), "a file is not a destination")

        let readOnly = under(downloads, "readonly")
        try mkdir(readOnly)
        try chmod(readOnly, 0o500)
        XCTAssertFalse(SaveFolderBrowser.canSave(into: readOnly))
    }

    func testPlacesOfferDownloadsHomeAndComputer() {
        let names = SaveFolderBrowser.places(defaultFolder: downloads, home: base).map(\.name)
        XCTAssertEqual(names.prefix(2).map { $0 }, ["Downloads", "Home"])
        XCTAssertTrue(names.contains("Computer"))
    }

    func testPlacesDoNotRepeatAPathUnderTwoNames() {
        let places = SaveFolderBrowser.places(defaultFolder: base, home: base)
        XCTAssertEqual(places.filter { $0.path == base }.count, 1)
    }

    func testPlacesSkipAFolderThatDoesNotExist() {
        let places = SaveFolderBrowser.places(
            defaultFolder: under(base, "gone"), home: base)
        XCTAssertFalse(places.contains { $0.name == "Downloads" })
    }

    func testCreateMakesTheFolderAndReturnsItsPath() throws {
        let made = try XCTUnwrap(
            SaveFolderBrowser.create(named: "ISOs", in: nil, defaultFolder: downloads))
        XCTAssertEqual(made, under(downloads, "ISOs"))
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: made, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testCreateWorksOutsideTheDownloadsFolder() throws {
        XCTAssertEqual(
            SaveFolderBrowser.create(named: "ISOs", in: sibling, defaultFolder: downloads),
            under(sibling, "ISOs"))
    }

    func testCreatingAFolderThatAlreadyExistsSucceeds() throws {
        try mkdir(under(downloads, "ISOs"))
        XCTAssertEqual(
            SaveFolderBrowser.create(named: "ISOs", in: nil, defaultFolder: downloads),
            under(downloads, "ISOs"))
    }

    func testCreateRefusesWhenAFileAlreadyHasTheName() {
        FileManager.default.createFile(atPath: under(downloads, "ISOs"), contents: Data())
        XCTAssertNil(SaveFolderBrowser.create(named: "ISOs", in: nil, defaultFolder: downloads))
    }

    func testCreateFailsWhereTheUserMayNotWrite() throws {
        try skipIfRoot()
        let readOnly = under(downloads, "readonly")
        try mkdir(readOnly)
        try chmod(readOnly, 0o500)

        XCTAssertNil(SaveFolderBrowser.create(named: "ISOs", in: readOnly, defaultFolder: downloads))
        XCTAssertFalse(FileManager.default.fileExists(atPath: under(readOnly, "ISOs")))
    }

    func testPlainFolderNamesAreAccepted() {
        for name in ["ISOs", "Linux Distros", "2024-releases", "naïve", "a.b"] {
            XCTAssertTrue(RemoteRouter.isPlainFolderName(name), name)
        }
    }

    /// Refused rather than sanitised — the name is a single component by construction, which is what lets `create` join it without re-checking where the result landed.
    func testTraversalSlashesHiddenAndEmptyNamesAreRefused() {
        for name in ["", "   ", ".", "..", "../etc", "a/b", #"a\b"#, ".hidden", "a\nb", "a\0b"] {
            XCTAssertFalse(RemoteRouter.isPlainFolderName(name), name)
        }
    }

    func testAnAbsurdlyLongNameIsRefused() {
        XCTAssertFalse(RemoteRouter.isPlainFolderName(String(repeating: "x", count: 241)))
        XCTAssertTrue(RemoteRouter.isPlainFolderName(String(repeating: "x", count: 240)))
    }
}
