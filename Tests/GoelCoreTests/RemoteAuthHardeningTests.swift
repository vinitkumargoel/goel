import XCTest
@testable import GoelCore

/// Regressions for two ways the portal could authenticate someone it should not: a login that
/// outlives the credentials it was judged against, and header SSO trusting a peer address alone.
final class RemoteAuthHardeningTests: XCTestCase {

    private func request(headers: [String: String], body: String = "") -> RemoteRequest {
        var raw = "POST /login HTTP/1.1\r\n"
        for (key, value) in headers { raw += "\(key): \(value)\r\n" }
        raw += "\r\n\(body)"
        return RemoteRequest(raw: Data(raw.utf8))
    }

    // MARK: - Credential rotation during PBKDF2

    /// The whole point of the epoch: a login that entered the slow password verification before the
    /// admin rotated the password must not come back and mint a session for the revoked credential.
    func testLoginThatRacesACredentialRotationIsRefused() async {
        let store = RemoteSessionStore()
        // Both hashes up front: deriving the replacement mid-race would let the login finish before
        // the rotation lands. ``PortalTestCredentials`` so the suite pays per derivation, not per test.
        let oldHash = PortalTestCredentials.hash
        let newHash = PortalTestCredentials.rotatedHash
        await store.configure(username: "admin", passwordHash: oldHash, sessionMinutes: 120)

        // Start the login, pause long enough to reach the detached PBKDF2 run (210,000 iterations —
        // far longer than this), then rotate underneath it. Assertions hold either way, so non-flaky.
        async let response = store.handleLogin(
            request(headers: ["Content-Type": "application/json"],
                    body: #"{"username":"admin","password":"\#(PortalTestCredentials.password)"}"#),
            client: "203.0.113.9")
        try? await Task.sleep(nanoseconds: 20_000_000)
        await store.configure(username: "admin", passwordHash: newHash,
                              sessionMinutes: 120, invalidatingSessions: true)

        let body = await response
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 401"),
                      "a login judged against rotated-away credentials must fail")
        XCTAssertFalse(text.contains("Set-Cookie"),
                       "no session cookie may be issued for a revoked password")
    }

    /// Re-applying identical credentials through `configure` must not move the epoch, or every settings
    /// save would randomly fail an in-flight sign-in. Also the happy path: 200 with a cookie.
    func testUnchangedCredentialsDoNotDisturbAnInFlightLogin() async {
        let store = RemoteSessionStore()
        let hash = PortalTestCredentials.hash
        await store.configure(username: "admin", passwordHash: hash, sessionMinutes: 120)

        async let response = store.handleLogin(
            request(headers: [:],
                    body: #"{"username":"admin","password":"\#(PortalTestCredentials.password)"}"#),
            client: "203.0.113.9")
        try? await Task.sleep(nanoseconds: 20_000_000)
        await store.configure(username: "admin", passwordHash: hash, sessionMinutes: 240)

        let body = await response
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200"))
        XCTAssertTrue(text.contains("goel_session="))
    }

    // MARK: - Trusted-header SSO needs more than a peer address

    /// The documented deployment is a same-host reverse proxy, so `127.0.0.1` identifies every local
    /// process equally. Without the shared secret the header must buy nothing at all.
    func testLoopbackPeerWithoutTheSharedSecretIsNotTrusted() {
        let policy = TrustedIdentityHeaderPolicy(isEnabled: true, trustedProxies: ["127.0.0.1"])
        XCTAssertFalse(policy.isEffective)
        XCTAssertNil(RemoteAuthService.trustedIdentity(
            request(headers: ["X-Forwarded-User": "alice"]), client: "127.0.0.1", policy: policy),
            "any local process could send this header; the address is not proof of proxy origin")
    }

    func testSharedSecretUnlocksTheHeaderAndAWrongOneDoesNot() {
        let policy = TrustedIdentityHeaderPolicy(isEnabled: true, trustedProxies: ["127.0.0.1"],
                                                 sharedSecret: "proxy-only-secret")
        XCTAssertTrue(policy.isEffective)

        XCTAssertEqual(RemoteAuthService.trustedIdentity(
            request(headers: ["X-Forwarded-User": "alice",
                              "X-Goel-Proxy-Secret": "proxy-only-secret"]),
            client: "127.0.0.1", policy: policy), "alice")

        XCTAssertNil(RemoteAuthService.trustedIdentity(
            request(headers: ["X-Forwarded-User": "alice",
                              "X-Goel-Proxy-Secret": "guess"]),
            client: "127.0.0.1", policy: policy))

        // The secret is an addition to the address check, not a replacement.
        XCTAssertNil(RemoteAuthService.trustedIdentity(
            request(headers: ["X-Forwarded-User": "alice",
                              "X-Goel-Proxy-Secret": "proxy-only-secret"]),
            client: "203.0.113.9", policy: policy),
            "a leaked secret from an untrusted address must still be refused")
    }
}
