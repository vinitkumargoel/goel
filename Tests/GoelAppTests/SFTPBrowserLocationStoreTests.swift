import XCTest
@testable import GoelApp

final class SFTPBrowserLocationStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var store: SFTPBrowserLocationStore!

    override func setUp() {
        super.setUp()
        suiteName = "goel.sftpbrowser.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = SFTPBrowserLocationStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testAConnectionWeHaveNeverVisitedHasNoRememberedFolder() {
        XCTAssertNil(store.path(for: UUID()))
    }

    func testAPathRoundTrips() {
        let id = UUID()
        store.setPath("/home/goel/Downloads", for: id)
        XCTAssertEqual(store.path(for: id), "/home/goel/Downloads")
    }

    func testAnEmptyPathIsStoredAsTheHomeShorthand() {
        let id = UUID()
        store.setPath("", for: id)
        XCTAssertEqual(store.path(for: id), ".",
                       "an empty string would open the browser at the filesystem root")
    }

    func testTheLatestPathWins() {
        let id = UUID()
        store.setPath("/first", for: id)
        store.setPath("/second", for: id)
        XCTAssertEqual(store.path(for: id), "/second")
    }

    func testConnectionsDoNotSeeEachOthersFolders() {
        let a = UUID(), b = UUID()
        store.setPath("/a", for: a)
        store.setPath("/b", for: b)
        XCTAssertEqual(store.path(for: a), "/a")
        XCTAssertEqual(store.path(for: b), "/b")
    }

    func testRemovingOneConnectionLeavesTheOthersAlone() {
        let a = UUID(), b = UUID()
        store.setPath("/a", for: a)
        store.setPath("/b", for: b)
        store.removePath(for: a)
        XCTAssertNil(store.path(for: a))
        XCTAssertEqual(store.path(for: b), "/b")
    }

    func testRemovingAConnectionWeNeverStoredIsHarmless() {
        store.setPath("/a", for: UUID())
        store.removePath(for: UUID())
        XCTAssertEqual(defaults.dictionary(forKey: "GoelDownloader.SFTPBrowserLastFolders")?.count, 1)
    }

    /// Anything can land in a defaults key — another build, a bad sync, a user with `defaults write`.
    func testAValueOfTheWrongShapeReadsAsEmptyRatherThanCrashing() {
        defaults.set(["not", "a", "dictionary"], forKey: "GoelDownloader.SFTPBrowserLastFolders")
        XCTAssertNil(store.path(for: UUID()))

        let id = UUID()
        store.setPath("/recovered", for: id)
        XCTAssertEqual(store.path(for: id), "/recovered",
                       "a junk value must be replaced, not permanently poison the store")
    }
}
