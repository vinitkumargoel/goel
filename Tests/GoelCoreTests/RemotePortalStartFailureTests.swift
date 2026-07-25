#if !os(Linux)
import XCTest
@testable import GoelCore

/// A refused portal start must be *reportable*, not just logged.
///
/// Both refusals in ``RemoteControlServer/start(port:allowLAN:config:passwordHash:sessionMinutes:security:)``
/// are fail-closed on purpose, but a silent fail-closed is indistinguishable from
/// success — that is what let the UI keep offering "Open" for a portal that never
/// bound. These tests pin the reason surviving in ``RemoteControlServer/lastStartFailure()``.
final class RemotePortalStartFailureTests: XCTestCase {

    private func config() -> RemoteRouter.Config {
        RemoteRouter.Config(token: "t", requireAuth: true, readOnly: false,
                            theme: "frost-dark", username: "admin")
    }

    /// TLS on with an identity that cannot be loaded: nothing listens, and the
    /// reason names the certificate path so the message can point at the typo.
    func testUnloadableTLSIdentityIsReported() async {
        let manager = DownloadManager()
        let server = RemoteControlServer(manager: manager)
        let missing = NSTemporaryDirectory() + "goel-no-such-identity.p12"
        await server.start(port: LoopbackPort.reserve(), allowLAN: false, config: config(),
                           passwordHash: PortalTestCredentials.hash, sessionMinutes: 120,
                           security: RemotePortalSecurity(tlsEnabled: true,
                                                          tlsIdentityPath: missing))
        let bound = await server.boundState()
        XCTAssertNil(bound)
        let failure = await server.lastStartFailure()
        XCTAssertEqual(failure, .tlsIdentityUnavailable(path: missing))
        // The text is what the UI shows, so it must name both the path and the
        // passphrase variable — the two things that are actually wrong.
        XCTAssertTrue(failure?.message.contains(missing) == true)
        XCTAssertTrue(failure?.message.contains("GOEL_PORTAL_TLS_PASSPHRASE") == true)
        await server.stop()
    }

    /// A successful bind clears any earlier refusal, and an explicit stop is not
    /// itself reported as a failure.
    func testSuccessfulStartAndStopClearTheFailure() async {
        let manager = DownloadManager()
        let server = RemoteControlServer(manager: manager)
        let cfg = config()
        let hash = PortalTestCredentials.hash
        await server.start(port: LoopbackPort.reserve(), allowLAN: false, config: cfg,
                           passwordHash: hash, sessionMinutes: 120,
                           security: RemotePortalSecurity(tlsEnabled: true,
                                                          tlsIdentityPath: "/definitely/not/here.p12"))
        var failure = await server.lastStartFailure()
        XCTAssertNotNil(failure)

        // A kernel-reserved port, so no concurrent test process can be holding it;
        // a restricted CI that still refuses the bind must report *that* instead of
        // the stale TLS reason, which is the property under test either way.
        let port = LoopbackPort.reserve()
        await server.start(port: port, allowLAN: false, config: cfg,
                           passwordHash: hash, sessionMinutes: 120)
        failure = await server.lastStartFailure()
        if await server.boundState() != nil {
            XCTAssertNil(failure)
        } else {
            XCTAssertEqual(failure, .bindFailed(port: port))
        }

        await server.stop()
        let afterStop = await server.lastStartFailure()
        XCTAssertNil(afterStop)
    }
}
#endif
