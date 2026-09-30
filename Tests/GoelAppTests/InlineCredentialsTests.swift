import XCTest
import GoelCore
@testable import GoelApp

final class InlineCredentialsTests: XCTestCase {

    private final class MemoryStore: CredentialManaging, @unchecked Sendable {
        var saved: [String: (String, String)] = [:]
        var writes = 0
        func credential(forHost host: String) -> (username: String, password: String)? {
            saved[host].map { (username: $0.0, password: $0.1) }
        }
        func setCredential(username: String, password: String, host: String) -> Bool {
            writes += 1
            saved[host] = (username, password)
            return true
        }
        func removeCredential(host: String) -> Bool { saved[host] = nil; return true }
        func allCredentials() -> [HostCredential] { [] }
    }

    func testTheLoginIsFoundAndTheSourceStaysClean() {
        let line = "https://alice:s3cr%40t@files.example.com/report.pdf"
        let found = InlineCredentials.find(in: line)
        XCTAssertEqual(found?.host, "files.example.com")
        XCTAssertEqual(found?.username, "alice")
        XCTAssertEqual(found?.password, "s3cr@t")
        XCTAssertEqual(found?.isTLS, true)
        XCTAssertFalse(DownloadSource.parse(line)!.locator.contains("alice"))
    }

    func testPlainLinksCarryNoLogin() {
        XCTAssertNil(InlineCredentials.find(in: "https://files.example.com/report.pdf"))
        XCTAssertNil(InlineCredentials.find(in: "magnet:?xt=urn:btih:abc"))
    }

    func testFindAllTakesOneLoginPerHost() {
        let raw = "https://a:1@h.test/x\nhttps://a:2@h.test/y\nhttps://b:3@k.test/z"
        XCTAssertEqual(InlineCredentials.findAll(in: raw).map(\.host), ["h.test", "k.test"])
    }

    func testTheUserReplacesButTheExtensionNeverOverwrites() {
        let store = MemoryStore()
        store.saved["h.test"] = ("owner", "pw")
        let fromPage = InlineCredentials.Found(host: "h.test", username: "evil", password: "x", isTLS: true)
        XCTAssertEqual(InlineCredentials.adopt(fromPage, into: store, policy: .keepExisting),
                       .keptExisting(host: "h.test"))
        XCTAssertEqual(store.saved["h.test"]?.0, "owner")
        XCTAssertEqual(InlineCredentials.adopt(fromPage, into: store, policy: .replace),
                       .stored(host: "h.test", isTLS: true))
        XCTAssertEqual(store.saved["h.test"]?.0, "evil")
    }

    func testTheExtensionMayAddALoginWhereNoneExists() {
        let store = MemoryStore()
        let found = InlineCredentials.Found(host: "nas.local", username: "me", password: "pw", isTLS: false)
        XCTAssertEqual(InlineCredentials.adopt(found, into: store, policy: .keepExisting),
                       .stored(host: "nas.local", isTLS: false))
        XCTAssertEqual(store.saved["nas.local"]?.1, "pw")
    }

    func testTheSameLoginIsNotRewritten() {
        let store = MemoryStore()
        store.saved["h.test"] = ("a", "b")
        let found = InlineCredentials.Found(host: "h.test", username: "a", password: "b", isTLS: true)
        _ = InlineCredentials.adopt(found, into: store, policy: .replace)
        XCTAssertEqual(store.writes, 0)
    }

    func testDecodeRoundTripsTheCoreHeader() {
        let parsed = DownloadSource.parseWithCredentials("https://u:p:q@h.test/f")
        let found = parsed?.authorization.flatMap {
            InlineCredentials.decode(authorization: $0, host: "h.test", isTLS: true)
        }
        XCTAssertEqual(found?.username, "u")
        XCTAssertEqual(found?.password, "p:q")
    }
}
