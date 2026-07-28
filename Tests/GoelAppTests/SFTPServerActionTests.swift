import XCTest
import GoelCore
@testable import GoelApp

final class SFTPServerActionTests: XCTestCase {

    func testDefaultPortIsOmittedAndNonDefaultIsKept() {
        XCTAssertEqual(AppViewModel.sshURL(username: "vinit", host: "example.com", port: 22)?.absoluteString,
                       "ssh://vinit@example.com")
        XCTAssertEqual(AppViewModel.sshURL(username: "vinit", host: "example.com", port: 2222)?.absoluteString,
                       "ssh://vinit@example.com:2222")
    }

    /// `URLComponents`, not interpolation: a username containing `@` must stay in the user half rather than re-point the address at an attacker's host.
    func testUsernameCannotReshapeTheHost() {
        let url = AppViewModel.sshURL(username: "vinit@evil.example", host: "example.com", port: 22)
        XCTAssertEqual(url?.host, "example.com")
        XCTAssertEqual(url?.user, "vinit@evil.example")
        XCTAssertFalse(url?.absoluteString.hasSuffix("evil.example") ?? true)
    }

    func testUsernameSpecialCharactersArePercentEncoded() {
        let url = AppViewModel.sshURL(username: "first last", host: "example.com", port: 22)
        XCTAssertEqual(url?.absoluteString, "ssh://first%20last@example.com")
        XCTAssertEqual(url?.user, "first last")
    }

    func testBlankUsernameStillProducesAHostOnlyURL() {
        XCTAssertEqual(AppViewModel.sshURL(username: "", host: "example.com", port: 22)?.absoluteString,
                       "ssh://example.com")
    }

    func testMissingHostYieldsNoURL() {
        XCTAssertNil(AppViewModel.sshURL(username: "vinit", host: "", port: 22))
    }

    // Both directions matter: a real host-key change must be called out, anything short of evidence must not.

    private static let keyA = String(repeating: "a", count: 64)
    private static let keyB = String(repeating: "b", count: 64)

    @MainActor
    func testChangedKeyIsAMismatch() {
        XCTAssertTrue(HostKeyInspector.isMismatch(pinned: .pinned(Self.keyA),
                                                  live: .read(Self.keyB)))
    }

    @MainActor
    func testMatchingKeyIsNotAMismatch() {
        XCTAssertFalse(HostKeyInspector.isMismatch(pinned: .pinned(Self.keyA),
                                                   live: .read(Self.keyA)))
    }

    @MainActor
    func testUnreachableServerIsNotAMismatch() {
        XCTAssertFalse(HostKeyInspector.isMismatch(pinned: .pinned(Self.keyA),
                                                   live: .unreachable("Connection refused")))
    }

    @MainActor
    func testUnpinnedServerIsNotAMismatch() {
        XCTAssertFalse(HostKeyInspector.isMismatch(pinned: .none, live: .read(Self.keyA)))
    }

    @MainActor
    func testUnreadablePinRecordIsNotAMismatch() {
        XCTAssertFalse(HostKeyInspector.isMismatch(pinned: .unavailable, live: .read(Self.keyA)))
    }
}
