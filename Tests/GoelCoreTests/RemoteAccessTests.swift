import XCTest
@testable import GoelCore

/// Pure policy for when the remote portal should run / reconfigure.
final class RemoteAccessTests: XCTestCase {

    private func settings(
        enabled: Bool = true,
        port: Int = 8899,
        lan: Bool = false,
        token: String = "t",
        requireAuth: Bool = true,
        username: String = "admin",
        passwordHash: String = "",
        readOnly: Bool = false,
        theme: String = "frost-dark",
        sessionMinutes: Int = 120
    ) -> AppSettings {
        var s = AppSettings()
        s.remoteAccessEnabled = enabled
        s.remotePort = port
        s.remoteAllowLAN = lan
        s.remoteToken = token
        s.remoteRequireAuth = requireAuth
        s.remoteUsername = username
        s.remotePasswordHash = passwordHash
        s.remoteReadOnly = readOnly
        s.remoteTheme = theme
        s.remoteSessionMinutes = sessionMinutes
        return s
    }

    func testShouldRunFollowsEnabledFlag() {
        XCTAssertTrue(RemoteAccessPolicy.shouldRun(settings(enabled: true)))
        XCTAssertFalse(RemoteAccessPolicy.shouldRun(settings(enabled: false)))
    }

    func testNeedsRestartFalseWhenIdentical() {
        let a = settings()
        XCTAssertFalse(RemoteAccessPolicy.needsRestart(previous: a, next: a))
    }

    func testNeedsRestartOnBindChange() {
        let a = settings(port: 8899, lan: false)
        XCTAssertTrue(RemoteAccessPolicy.needsRestart(previous: a, next: settings(port: 9900)))
        XCTAssertTrue(RemoteAccessPolicy.needsRestart(previous: a, next: settings(lan: true)))
    }

    func testNeedsRestartOnAuthOrTokenChange() {
        let a = settings()
        XCTAssertTrue(RemoteAccessPolicy.needsRestart(previous: a, next: settings(token: "other")))
        XCTAssertTrue(RemoteAccessPolicy.needsRestart(previous: a, next: settings(requireAuth: false)))
        XCTAssertTrue(RemoteAccessPolicy.needsRestart(previous: a, next: settings(username: "bob")))
        XCTAssertTrue(RemoteAccessPolicy.needsRestart(
            previous: a, next: settings(passwordHash: RemotePassword.hash("x"))))
    }

    func testNeedsRestartOnLiveConfigChange() {
        let a = settings()
        XCTAssertTrue(RemoteAccessPolicy.needsRestart(previous: a, next: settings(readOnly: true)))
        XCTAssertTrue(RemoteAccessPolicy.needsRestart(previous: a, next: settings(theme: "other")))
        XCTAssertTrue(RemoteAccessPolicy.needsRestart(previous: a, next: settings(sessionMinutes: 30)))
    }

    func testNeedsRestartIgnoresEnabledFlag() {
        // enabled is handled by shouldRun; comparison is for reconfigure-while-on.
        let a = settings(enabled: true)
        let b = settings(enabled: false)
        XCTAssertFalse(RemoteAccessPolicy.needsRestart(previous: a, next: b))
    }

    func testApplyStartsAndStops() async {
        let manager = DownloadManager()
        let access = RemoteAccess()
        var running = await access.isRunning
        XCTAssertFalse(running)

        await access.apply(settings: settings(enabled: true, port: 18980), backend: manager)
        running = await access.isRunning
        XCTAssertTrue(running)

        // No-op when nothing relevant changed.
        await access.apply(settings: settings(enabled: true, port: 18980), backend: manager)
        running = await access.isRunning
        XCTAssertTrue(running)

        await access.apply(settings: settings(enabled: false, port: 18980), backend: manager)
        running = await access.isRunning
        XCTAssertFalse(running)
        await access.stop()
    }
}
