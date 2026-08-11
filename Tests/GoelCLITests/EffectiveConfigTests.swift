import XCTest
@testable import GoelCLI

final class EffectiveConfigTests: XCTestCase {

    private func temporaryConfig(_ body: String) throws -> String {
        let path = NSTemporaryDirectory() + "goel-effective-test-\(UUID().uuidString)"
        try body.write(toFile: path, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        return path
    }

    func testFileValuesApplyWhenTheEnvironmentIsSilent() throws {
        let path = try temporaryConfig("""
        GOEL_PORT=9191
        GOEL_TOKEN=file-token
        GOEL_SAVE_DIR=/srv/media
        """)
        let effective = Effective(try ConfigFile(path: path), environment: [:])
        XCTAssertEqual(effective.port, 9191)
        XCTAssertEqual(effective.tokenFromConfig, "file-token")
        XCTAssertEqual(effective.saveDir, "/srv/media")
        XCTAssertTrue(effective.requireAuth, "auth defaults on, matching the daemon")
        XCTAssertFalse(effective.allowLAN)
    }

    /// The environment must outrank the file — it is how agents point one `goel`
    /// invocation at another daemon without touching anyone's config.
    func testEnvironmentOutranksTheFile() throws {
        let path = try temporaryConfig("""
        GOEL_PORT=9191
        GOEL_TOKEN=file-token
        """)
        let effective = Effective(try ConfigFile(path: path),
                                  environment: ["GOEL_PORT": "7777",
                                                "GOEL_TOKEN": "env-token"])
        XCTAssertEqual(effective.port, 7777)
        XCTAssertEqual(effective.tokenFromConfig, "env-token")
    }

    func testEmptyEnvironmentValueDoesNotMaskTheFile() throws {
        let path = try temporaryConfig("GOEL_PORT=9191\n")
        let effective = Effective(try ConfigFile(path: path), environment: ["GOEL_PORT": ""])
        XCTAssertEqual(effective.port, 9191)
    }

    func testAnAbsentFileCanBeCreatedAndSaved() throws {
        let path = NSTemporaryDirectory() + "goel-created-\(UUID().uuidString)"
        addTeardownBlock { try? FileManager.default.removeItem(atPath: path) }
        var config = ConfigFile(creatingAt: path)
        config.set(env: "GOEL_PORT", to: "8123")
        try config.save()
        let reread = try ConfigFile(path: path)
        XCTAssertEqual(reread.value(forEnv: "GOEL_PORT"), "8123")
        // The file may carry the portal password: it must be born private.
        let mode = try XCTUnwrap((try FileManager.default
            .attributesOfItem(atPath: path))[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.uint16Value & 0o077, 0, "config must not be group/world readable")
    }

    func testConfigPathOverrideWinsAndBlankIsIgnored() {
        XCTAssertEqual(Layout.resolveConfigPath(environment: ["GOEL_CONFIG": "/x/y/config"]),
                       "/x/y/config")
        let noOverride = Layout.resolveConfigPath(environment: ["GOEL_CONFIG": ""])
        XCTAssertNotEqual(noOverride, "", "a blank override must fall through, not be honoured")
    }

    /// Exit codes are a documented contract for agents; renumbering one is a breaking change.
    func testExitCodesAreTheDocumentedContract() {
        XCTAssertEqual(ExitCode.ok, 0)
        XCTAssertEqual(ExitCode.error, 1)
        XCTAssertEqual(ExitCode.usage, 2)
        XCTAssertEqual(ExitCode.downloadFailed, 3)
        XCTAssertEqual(ExitCode.timedOut, 4)
        XCTAssertEqual(ExitCode.detached, 130)
    }
}
