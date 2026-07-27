import XCTest
import GoelCore
@testable import GoelApp

final class SFTPBrowserNavigationTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SFTPBrowserNavigationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testLocationsPersistIndependentlyAcrossStoreInstances() {
        let first = UUID()
        let second = UUID()
        let store = SFTPBrowserLocationStore(defaults: defaults)

        store.setPath("projects/releases", for: first)
        store.setPath("/srv/uploads", for: second)

        let reloaded = SFTPBrowserLocationStore(defaults: defaults)
        XCTAssertEqual(reloaded.path(for: first), "projects/releases")
        XCTAssertEqual(reloaded.path(for: second), "/srv/uploads")
    }

    func testRemovingLocationOnlyAffectsRequestedServer() {
        let first = UUID()
        let second = UUID()
        let store = SFTPBrowserLocationStore(defaults: defaults)
        store.setPath("one", for: first)
        store.setPath("two", for: second)

        store.removePath(for: first)

        XCTAssertNil(store.path(for: first))
        XCTAssertEqual(store.path(for: second), "two")
    }

    func testEmptyPathIsStoredAsHomeAndMalformedRecordIsIgnored() {
        let id = UUID()
        let store = SFTPBrowserLocationStore(defaults: defaults)
        store.setPath("", for: id)
        XCTAssertEqual(store.path(for: id), ".")

        defaults.set(["not", "a", "path", "map"],
                     forKey: "GoelDownloader.SFTPBrowserLastFolders")
        XCTAssertNil(store.path(for: id))
    }

    func testTransferRemoteFolderDerivation() {
        let id = UUID()
        let local = URL(fileURLWithPath: "/tmp/file")

        let relative = SFTPTransfer(connectionID: id, name: "file.zip", direction: .upload,
                                    isDirectory: false, localURL: local,
                                    remotePath: "uploads/file.zip")
        XCTAssertEqual(relative.remoteFolder, "uploads")
        XCTAssertEqual(relative.remoteFolderLabel, "uploads")

        let home = SFTPTransfer(connectionID: id, name: "file.zip", direction: .upload,
                                isDirectory: false, localURL: local,
                                remotePath: "file.zip")
        XCTAssertEqual(home.remoteFolder, ".")
        XCTAssertEqual(home.remoteFolderLabel, "Home")

        let absolute = SFTPTransfer(connectionID: id, name: "file.dmg", direction: .download,
                                    isDirectory: false, localURL: local,
                                    remotePath: "/srv/releases/file.dmg")
        XCTAssertEqual(absolute.remoteFolder, "/srv/releases")

        let root = SFTPTransfer(connectionID: id, name: "file", direction: .download,
                                isDirectory: false, localURL: local,
                                remotePath: "/file")
        XCTAssertEqual(root.remoteFolder, "/")
    }

    func testNavigationRequestCarriesServerAndFolderIdentity() {
        let serverID = UUID()
        let requestID = UUID()
        let request = SFTPBrowserNavigationRequest(
            id: requestID,
            connectionID: serverID,
            path: "/srv/releases")

        XCTAssertEqual(request.id, requestID)
        XCTAssertEqual(request.connectionID, serverID)
        XCTAssertEqual(request.path, "/srv/releases")
    }
}
