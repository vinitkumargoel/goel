import XCTest
@testable import GoelCLI

/// `/etc/goel/config` is a systemd `EnvironmentFile`: a mangled line means a wrong value or a refused
/// file, so the service stops booting on the restart `goel config set` triggers immediately.
final class ConfigFileTests: XCTestCase {

    private var path = ""

    override func setUpWithError() throws {
        path = FileManager.default.temporaryDirectory
            .appendingPathComponent("goel-config-\(UUID().uuidString)").path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func write(_ contents: String) throws {
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    private func read() throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    // MARK: Reading

    func testReadsPlainAssignment() throws {
        try write("GOEL_PORT=9090\n")
        let config = try ConfigFile(path: path)
        XCTAssertEqual(config.value(forEnv: "GOEL_PORT"), "9090")
    }

    func testIgnoresCommentsAndBlankLines() throws {
        try write("# a comment\n\n  # indented\nGOEL_PORT=1\n")
        let config = try ConfigFile(path: path)
        XCTAssertEqual(config.value(forEnv: "GOEL_PORT"), "1")
        XCTAssertNil(config.value(forEnv: "# a comment"))
    }

    /// systemd strips one layer of matching quotes, so a quoted value must read back unquoted —
    /// otherwise `goel config get save-dir` shows `"/mnt/x"` and a later `set` re-quotes the quotes.
    func testStripsOneLayerOfQuotes() throws {
        try write("GOEL_SAVE_DIR=\"/mnt/my downloads\"\nGOEL_USERNAME='ad min'\n")
        let config = try ConfigFile(path: path)
        XCTAssertEqual(config.value(forEnv: "GOEL_SAVE_DIR"), "/mnt/my downloads")
        XCTAssertEqual(config.value(forEnv: "GOEL_USERNAME"), "ad min")
    }

    /// systemd lets the last assignment win. Reading the first one would report a
    /// value the daemon is not actually running with.
    func testLastAssignmentWins() throws {
        try write("GOEL_PORT=1\nGOEL_PORT=2\n")
        XCTAssertEqual(try ConfigFile(path: path).value(forEnv: "GOEL_PORT"), "2")
    }

    func testAbsentKeyIsNilAndEmptyIsEmpty() throws {
        try write("GOEL_TOKEN=\n")
        let config = try ConfigFile(path: path)
        XCTAssertEqual(config.value(forEnv: "GOEL_TOKEN"), "",
                       "KEY= is set-but-empty, which is not the same as absent")
        XCTAssertNil(config.value(forEnv: "GOEL_PORT"))
    }

    func testMissingFileThrowsNotInstalled() {
        XCTAssertThrowsError(try ConfigFile(path: path + "-nope")) { error in
            guard case .notInstalled = error as? CLIError else {
                return XCTFail("expected .notInstalled, got \(error)")
            }
        }
    }

    /// The file is 0600 root-only, so an unreadable one means "you forgot sudo",
    /// not "Goel° is not installed" — which is what it used to say.
    func testUnreadableFileThrowsNeedsRootNotNotInstalled() throws {
        try XCTSkipIf(geteuid() == 0, "root can read anything, so there is nothing to test")
        try write("GOEL_PORT=8080\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        XCTAssertThrowsError(try ConfigFile(path: path)) { error in
            guard case .needsRoot = error as? CLIError else {
                return XCTFail("expected .needsRoot, got \(error)")
            }
        }
    }

    // MARK: Writing

    func testSetReplacesInPlaceAndPreservesComments() throws {
        try write("# keep me\nGOEL_PORT=8080\nGOEL_USERNAME=admin\n")
        var config = try ConfigFile(path: path)
        config.set(env: "GOEL_PORT", to: "9090")
        try config.save()
        let contents = try read()
        XCTAssertTrue(contents.contains("# keep me"), "operator comments must survive a set")
        XCTAssertTrue(contents.contains("GOEL_PORT=9090"))
        XCTAssertFalse(contents.contains("8080"))
        XCTAssertTrue(contents.contains("GOEL_USERNAME=admin"), "unrelated keys must be untouched")
    }

    func testSetAppendsWhenAbsent() throws {
        try write("GOEL_PORT=8080\n")
        var config = try ConfigFile(path: path)
        config.set(env: "GOEL_SAVE_DIR", to: "/srv/dl")
        try config.save()
        XCTAssertTrue(try read().contains("GOEL_SAVE_DIR=/srv/dl"))
    }

    /// A duplicate left behind would mean the file says two things and systemd
    /// silently picks the later one — so `set` must collapse them.
    func testSetCollapsesDuplicates() throws {
        try write("GOEL_PORT=1\nGOEL_PORT=2\nGOEL_PORT=3\n")
        var config = try ConfigFile(path: path)
        config.set(env: "GOEL_PORT", to: "9")
        try config.save()
        let occurrences = try read().components(separatedBy: "GOEL_PORT=").count - 1
        XCTAssertEqual(occurrences, 1, "exactly one assignment should remain")
        XCTAssertTrue(try read().contains("GOEL_PORT=9"))
    }

    func testUnsetRemovesEveryAssignment() throws {
        try write("GOEL_PORT=1\nGOEL_TOKEN=abc\nGOEL_TOKEN=def\n")
        var config = try ConfigFile(path: path)
        config.unset(env: "GOEL_TOKEN")
        try config.save()
        let contents = try read()
        XCTAssertFalse(contents.contains("GOEL_TOKEN"))
        XCTAssertTrue(contents.contains("GOEL_PORT=1"))
    }

    /// systemd splits unquoted values on whitespace and treats `#` as a comment even mid-line, so a
    /// spaced path or a `#` password MUST come back intact or the daemon boots with a truncated value.
    func testQuotesValuesSystemdWouldOtherwiseSplit() throws {
        try write("GOEL_PORT=8080\n")
        var config = try ConfigFile(path: path)
        config.set(env: "GOEL_SAVE_DIR", to: "/mnt/my downloads")
        config.set(env: "GOEL_PASSWORD", to: "pa#ss word\"quoted\"")
        try config.save()

        let reread = try ConfigFile(path: path)
        XCTAssertEqual(reread.value(forEnv: "GOEL_SAVE_DIR"), "/mnt/my downloads")
        // The quoting must survive a full round trip, escapes and all.
        XCTAssertTrue(try read().contains("GOEL_SAVE_DIR=\"/mnt/my downloads\""))
        XCTAssertTrue(try read().contains("\\\""), "embedded quotes must be escaped")
    }

    func testSaveIsAtomicAndPrivate() throws {
        try write("GOEL_PORT=8080\n")
        var config = try ConfigFile(path: path)
        config.set(env: "GOEL_PASSWORD", to: "hunter22")
        try config.save()

        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let mode = (attributes[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
        XCTAssertEqual(mode & 0o777, 0o600,
                       "the file holds the portal password in plaintext")
        // No temporary file may be left behind next to it.
        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: (path as NSString).deletingLastPathComponent)
        let base = (path as NSString).lastPathComponent
        XCTAssertFalse(siblings.contains { $0.hasPrefix(base) && $0.contains(".tmp.") })
    }

    func testRoundTripsEveryKnownSetting() throws {
        try write("")
        var config = try ConfigFile(path: path)
        for setting in settings {
            config.set(env: setting.env, to: "value-for-\(setting.key)")
        }
        try config.save()
        let reread = try ConfigFile(path: path)
        for setting in settings {
            XCTAssertEqual(reread.value(forEnv: setting.env), "value-for-\(setting.key)",
                           "\(setting.key) did not survive a round trip")
        }
    }

    // MARK: Effective values

    /// These defaults have to match Sources/GoelDaemon/main.swift, or the CLI
    /// reports a port and a database the daemon is not using.
    func testEffectiveMirrorsDaemonDefaults() throws {
        try write("")
        let effective = Effective(try ConfigFile(path: path))
        XCTAssertEqual(effective.port, 8080)
        XCTAssertEqual(effective.username, "admin")
        XCTAssertFalse(effective.allowLAN, "the daemon defaults GOEL_ALLOW_LAN to false")
        XCTAssertTrue(effective.requireAuth, "the daemon defaults GOEL_REQUIRE_AUTH to true")
        XCTAssertNil(effective.watchDir)
        // The daemon's own fallbacks are relative to its HOME, not to /var/lib/goel
        // directly — asserting the wrong ones here is how the divergence survived.
        let home = Effective.daemonHome
        XCTAssertEqual(effective.databasePath, home + "/.local/share/goel-downloader/queue.sqlite")
        XCTAssertEqual(effective.saveDir, home + "/Downloads")
    }

    /// The token lives next to the database, so a wrong database default sends every
    /// authenticated command looking in a directory the daemon never wrote to.
    func testTokenFileFollowsTheDatabase() throws {
        try write("GOEL_DB=/srv/goel/queue.sqlite\n")
        let effective = Effective(try ConfigFile(path: path))
        XCTAssertEqual(Layout.tokenFile(databasePath: effective.databasePath),
                       "/srv/goel/portal-token")
    }

    func testEffectiveReadsBoolSpellingsTheDaemonAccepts() throws {
        for spelling in ["1", "true", "yes", "on", "TRUE", "On"] {
            try write("GOEL_ALLOW_LAN=\(spelling)\n")
            XCTAssertTrue(Effective(try ConfigFile(path: path)).allowLAN, "\(spelling) should be true")
        }
        for spelling in ["0", "false", "no", "off", ""] {
            try write("GOEL_ALLOW_LAN=\(spelling)\n")
            XCTAssertFalse(Effective(try ConfigFile(path: path)).allowLAN, "\(spelling) should be false")
        }
    }

    func testTokenPrefersConfigOverFile() throws {
        try write("GOEL_TOKEN=from-config\n")
        XCTAssertEqual(try Effective(try ConfigFile(path: path)).token(), "from-config")
    }

    // MARK: Validation

    func testPortValidationRejectsWhatTheUnitCannotBind() {
        XCTAssertNil(Validators.port("8080"))
        XCTAssertNotNil(Validators.port("0"))
        XCTAssertNotNil(Validators.port("70000"))
        XCTAssertNotNil(Validators.port("http"))
        // The unit grants no CAP_NET_BIND_SERVICE, so 80 would fail at start —
        // catching it here beats a service that refuses to boot.
        XCTAssertNotNil(Validators.port("80"))
    }

    func testOtherValidators() {
        XCTAssertNil(Validators.bool("yes"))
        XCTAssertNotNil(Validators.bool("maybe"))
        XCTAssertNil(Validators.absolutePath("/srv/dl"))
        XCTAssertNotNil(Validators.absolutePath("relative/dl"))
        XCTAssertNotNil(Validators.password("short"))
        XCTAssertNil(Validators.password("longenough"))
        XCTAssertNotNil(Validators.username(""))
        XCTAssertNotNil(Validators.username("two\nlines"))
    }

    /// Whatever this accepts gets created, recursively chowned to the service user
    /// and added to ReadWritePaths — so `/` and `/etc` must not get that far.
    func testAbsolutePathRefusesSystemDirectories() {
        for path in ["/", "/etc", "/etc/", "/usr", "/home", "//etc", "/etc/."] {
            XCTAssertNotNil(Validators.absolutePath(path), "\(path) should be refused")
        }
        XCTAssertNotNil(Validators.absolutePath("/srv/../etc"), "`..` should be refused")
        for path in ["/srv/goel", "/home/alice/Downloads", "/mnt/disk/dl", "/var/lib/goel"] {
            XCTAssertNil(Validators.absolutePath(path), "\(path) should be accepted")
        }
    }

    func testEverySettingKeyIsResolvableAndUnique() {
        XCTAssertEqual(Set(settings.map(\.key)).count, settings.count, "duplicate setting key")
        XCTAssertEqual(Set(settings.map(\.env)).count, settings.count, "duplicate env var")
        for entry in settings {
            XCTAssertEqual(setting(named: entry.key)?.env, entry.env)
            XCTAssertEqual(setting(named: entry.key.uppercased())?.env, entry.env,
                           "lookup should be case-insensitive")
        }
    }
}
