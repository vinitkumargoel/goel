import XCTest
import GoelCore
@testable import GoelApp

final class PendingMagnetTitleTests: XCTestCase {

    func testAPendingMagnetShowsItsShortInfoHash() {
        let magnet = DownloadTask(source: .magnet("magnet:?xt=urn:btih:5C1A9D3E77AA0011223344556677889900AABBCC"),
                                  name: "Magnet download", saveDirectory: "/tmp")
        XCTAssertEqual(magnet.compactDisplayName, "Magnet link (5c1a…)")
    }

    func testARawMagnetURIAsNameIsReplaced() {
        XCTAssertEqual(DownloadTask.pendingMagnetTitle(name: "magnet:?xt=urn:btih:ABCDEF0123456789",
                                                       infoHash: "ABCDEF0123456789"),
                       "Magnet link (abcd…)")
        XCTAssertEqual(DownloadTask.pendingMagnetTitle(name: "Magnet download", infoHash: nil),
                       "Magnet link")
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

    func testAPendingMagnetUsesItsDnNameWhenPresent() {
        let magnet = DownloadTask(source: .magnet("magnet:?xt=urn:btih:5C1A9D3E77AA0011223344556677889900AABBCC&dn=Demo+Pack%20v2&tr=udp%3A%2F%2Fx"),
                                  name: "Magnet download", saveDirectory: "/tmp", status: .requestingMetadata)
        XCTAssertEqual(magnet.compactDisplayName, "Demo Pack v2")
        XCTAssertEqual(DownloadTask.magnetDisplayName(in: "magnet:?dn=&xt=urn:btih:abc"), nil)
        XCTAssertEqual(DownloadTask.magnetDisplayName(in: "magnet:?xt=urn:btih:abc"), nil)
    }
}
