import XCTest
import GoelCore
@testable import GoelApp

/// The pure half of the sidebar's server session actions. Worth pinning here is the address handed to
/// another app — where a hostile saved username stops being Goel's problem and becomes `NSWorkspace`'s.
final class SFTPServerActionTests: XCTestCase {

    func testDefaultPortIsOmittedAndNonDefaultIsKept() {
        XCTAssertEqual(AppViewModel.sshURL(username: "vinit", host: "example.com", port: 22)?.absoluteString,
                       "ssh://vinit@example.com")
        XCTAssertEqual(AppViewModel.sshURL(username: "vinit", host: "example.com", port: 2222)?.absoluteString,
                       "ssh://vinit@example.com:2222")
    }

    /// Why `URLComponents` and not interpolation: a username containing `@` must stay in the user
    /// half of the URL rather than re-pointing the address at an attacker-chosen host.
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

    /// A connection saved without a host has nothing to open — better a nil the
    /// caller can report than an `ssh://` that opens Terminal on nowhere.
    func testMissingHostYieldsNoURL() {
        XCTAssertNil(AppViewModel.sshURL(username: "vinit", host: "", port: 22))
    }

    // MARK: Host-key comparison
    // Both directions matter: a real key change must be called out, anything short of evidence not.

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

    /// A firewalled or down server tells us nothing about its key.
    @MainActor
    func testUnreachableServerIsNotAMismatch() {
        XCTAssertFalse(HostKeyInspector.isMismatch(pinned: .pinned(Self.keyA),
                                                   live: .unreachable("Connection refused")))
    }

    /// First contact — there is nothing to disagree with yet.
    @MainActor
    func testUnpinnedServerIsNotAMismatch() {
        XCTAssertFalse(HostKeyInspector.isMismatch(pinned: .none, live: .read(Self.keyA)))
    }

    /// An unreadable pin record is a broken store, not a key change. Reporting it
    /// as a mismatch would send the user hunting for an attacker.
    @MainActor
    func testUnreadablePinRecordIsNotAMismatch() {
        XCTAssertFalse(HostKeyInspector.isMismatch(pinned: .unavailable, live: .read(Self.keyA)))
    }
}
