import XCTest
import GoelCore
@testable import GoelApp

final class PendingMagnetTitleTests: XCTestCase {

    func testAPendingMagnetShowsItsShortInfoHash() {
        let magnet = DownloadTask(source: .magnet("magnet:?xt=urn:btih:5C1A9D3E77AA0011223344556677889900AABBCC"),
                                  name: "Magnet download", saveDirectory: "/tmp")
        XCTAssertEqual(magnet.compactDisplayName, "Fetching metadata · 5c1a9d3e")
    }

    func testARawMagnetURIAsNameIsReplaced() {
        XCTAssertEqual(DownloadTask.pendingMagnetTitle(name: "magnet:?xt=urn:btih:ABCDEF0123456789",
                                                       infoHash: "ABCDEF0123456789"),
                       "Fetching metadata · abcdef01")
        XCTAssertEqual(DownloadTask.pendingMagnetTitle(name: "Magnet download", infoHash: nil),
                       "Fetching metadata")
    }

    func testARealNameIsKept() {
        XCTAssertNil(DownloadTask.pendingMagnetTitle(name: "Demo Pack", infoHash: "abc"))
        let named = DownloadTask(source: .magnet("magnet:?xt=urn:btih:abc&dn=Demo+Pack"),
                                 name: "Demo Pack", saveDirectory: "/tmp")
        XCTAssertEqual(named.compactDisplayName, "Demo Pack")
        let resolved = DownloadTask(source: .magnet("magnet:?xt=urn:btih:abc"),
                                    name: "Magnet download", saveDirectory: "/tmp", totalBytes: 100)
        XCTAssertEqual(resolved.compactDisplayName, "Magnet download", "metadata arrived: not pending")
    }
}
