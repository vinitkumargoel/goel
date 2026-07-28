#if !os(Linux)
import XCTest
@testable import GoelCore

final class RemotePortalStartFailureTests: XCTestCase {

    private func config() -> RemoteRouter.Config {
        RemoteRouter.Config(token: "t", requireAuth: true, readOnly: false,
                            theme: "frost-dark", username: "admin")
    }

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
        XCTAssertTrue(failure?.message.contains(missing) == true)
        XCTAssertTrue(failure?.message.contains("GOEL_PORTAL_TLS_PASSPHRASE") == true)
        await server.stop()
    }

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
