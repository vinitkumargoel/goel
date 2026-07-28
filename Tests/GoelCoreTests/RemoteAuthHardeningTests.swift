import XCTest
@testable import GoelCore

final class RemoteAuthHardeningTests: XCTestCase {

    private func request(headers: [String: String], body: String = "") -> RemoteRequest {
        var raw = "POST /login HTTP/1.1\r\n"
        for (key, value) in headers { raw += "\(key): \(value)\r\n" }
        raw += "\r\n\(body)"
        return RemoteRequest(raw: Data(raw.utf8))
    }

    /// A login already inside PBKDF2 when the password rotates must not mint a session.
    func testLoginThatRacesACredentialRotationIsRefused() async {
        let store = RemoteSessionStore()
        // Both hashes derived up front: deriving mid-race lets the login finish before the rotation lands.
        let oldHash = PortalTestCredentials.hash
        let newHash = PortalTestCredentials.rotatedHash
        await store.configure(username: "admin", passwordHash: oldHash, sessionMinutes: 120)

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

    /// Re-applying identical credentials must not move the epoch, or any settings save kills an in-flight login.
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

    /// `127.0.0.1` identifies every local process equally, so the header alone must buy nothing.
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
