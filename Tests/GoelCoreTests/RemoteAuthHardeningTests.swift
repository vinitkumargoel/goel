import XCTest
@testable import GoelCore

/// Regressions for two ways the portal could be talked into authenticating
/// someone it should not: a login that outlives the credentials it was judged
/// against, and header SSO trusting a peer address that proves nothing.
final class RemoteAuthHardeningTests: XCTestCase {

    private func request(headers: [String: String], body: String = "") -> RemoteRequest {
        var raw = "POST /login HTTP/1.1\r\n"
        for (key, value) in headers { raw += "\(key): \(value)\r\n" }
        raw += "\r\n\(body)"
        return RemoteRequest(raw: Data(raw.utf8))
    }

    // MARK: - Credential rotation during PBKDF2

    /// The whole point of the epoch: a login that entered the (slow) password
    /// verification before the admin rotated the password must not come back and
    /// mint a session for the credential that was just revoked.
    func testLoginThatRacesACredentialRotationIsRefused() async {
        let store = RemoteSessionStore()
        // Both hashes up front: hashing is as slow as verifying, so computing the
        // replacement mid-race would let the login finish before the rotation lands.
        let oldHash = RemotePassword.hash("old-secret")
        let newHash = RemotePassword.hash("new-secret")
        await store.configure(username: "admin", passwordHash: oldHash, sessionMinutes: 120)

        // Start the login, give it long enough to reach the detached PBKDF2 run
        // (210,000 iterations — far longer than this pause), then rotate underneath
        // it. The assertions below hold either way, so a slow machine that lets the
        // rotation land first still gets a meaningful, non-flaky test.
        async let response = store.handleLogin(
            request(headers: ["Content-Type": "application/json"],
                    body: #"{"username":"admin","password":"old-secret"}"#),
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

    /// Re-applying identical credentials (a theme or read-only change going
    /// through the same `configure` call) must not move the epoch, or every
    /// settings save would randomly fail an in-flight sign-in. Doubles as the
    /// happy-path check: this login must still come back 200 with a cookie.
    ///
    /// Only two tests here touch PBKDF2 — each one costs seconds of real work by
    /// design, so the coverage is deliberately kept to the two behaviours that
    /// cannot be observed any other way.
    func testUnchangedCredentialsDoNotDisturbAnInFlightLogin() async {
        let store = RemoteSessionStore()
        let hash = RemotePassword.hash("s3cret")
        await store.configure(username: "admin", passwordHash: hash, sessionMinutes: 120)

        async let response = store.handleLogin(
            request(headers: [:], body: #"{"username":"admin","password":"s3cret"}"#),
            client: "203.0.113.9")
        try? await Task.sleep(nanoseconds: 20_000_000)
        await store.configure(username: "admin", passwordHash: hash, sessionMinutes: 240)

        let body = await response
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200"))
        XCTAssertTrue(text.contains("goel_session="))
    }

    // MARK: - Trusted-header SSO needs more than a peer address

    /// The documented deployment is a same-host reverse proxy, so `127.0.0.1`
    /// identifies every local process equally. Without the shared secret the
    /// header must buy nothing at all.
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
