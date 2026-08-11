import XCTest
@testable import GoelCore

final class SecurityHardeningTests: XCTestCase {

    func testFTPInlinePasswordStrippedFromLocator() {
        let source = DownloadSource.parse("ftp://user:s3cret@ftp.example.com/file.zip")
        guard case .url(let url)? = source else { return XCTFail("expected .url") }
        XCTAssertNil(url.password, "inline FTP password must not survive parse")
        XCTAssertFalse(source!.locator.contains("s3cret"), "password must not persist in the locator")
        XCTAssertEqual(url.user, "user", "username is kept; only the secret is stripped")
        XCTAssertEqual(source!.kind, .ftp)
    }

    func testFTPSInlinePasswordStripped() {
        let source = DownloadSource.parse("ftps://a:b@host/x")
        guard case .url(let url)? = source else { return XCTFail("expected .url") }
        XCTAssertNil(url.password)
        XCTAssertFalse(source!.locator.contains(":b@"))
    }

    func testFTPWithoutPasswordIsUnchanged() {
        let source = DownloadSource.parse("ftp://ftp.gnu.org/gnu/x.tar.gz")
        XCTAssertEqual(source?.locator, "ftp://ftp.gnu.org/gnu/x.tar.gz")
    }

    func testIsContainedRejectsTraversalAndAbsolute() {
        let root = "/Users/me/Downloads"
        XCTAssertTrue(PathSafety.isContained("/Users/me/Downloads/movie.mp4", within: root))
        XCTAssertTrue(PathSafety.isContained(root, within: root))
        XCTAssertFalse(PathSafety.isContained("/Users/me/Downloads/../../.zshrc", within: root))
        XCTAssertFalse(PathSafety.isContained("/etc/cron.d/x", within: root))
        XCTAssertFalse(PathSafety.isContained("/Users/me/DownloadsEvil/x", within: root),
                       "prefix match must be on a path boundary, not a string prefix")
    }

    #if os(macOS)
    /// `resolvingSymlinksInPath` strips "/private" from a path that exists but not from one
    /// that is about to be created — the first write into /private/tmp must not read as escape.
    func testIsContainedAcceptsANewFileUnderPrivate() throws {
        let dir = "/private/tmp/goel-containment-test-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        XCTAssertTrue(PathSafety.isContained(dir + "/new-download.bin", within: dir),
                      "a not-yet-created file inside its own save directory is contained")
        XCTAssertFalse(PathSafety.isContained("/private/etc/cron.d/x", within: dir))
        XCTAssertFalse(PathSafety.isContained(dir + "/../escape.bin", within: dir))
    }
    #endif

    func testPrimaryFilePathRejectsEscapingTorrentEntry() {
        let dir = NSTemporaryDirectory()
        let files = [
            TransferFile(id: 0, path: "../../../../etc/passwd", length: 1_000_000),
            TransferFile(id: 1, path: "movie.mp4", length: 10),
        ]
        let task = DownloadTask(source: .magnet("magnet:?xt=urn:btih:abc"),
                                name: "t", saveDirectory: dir, files: files)
        // A traversing torrent path must fall back to savePath, never escape the save directory.
        XCTAssertTrue(PathSafety.isContained(task.primaryFilePath, within: dir)
                        || task.primaryFilePath == task.savePath)
        XCTAssertFalse(task.primaryFilePath.contains("/etc/passwd"))
    }

    private func request(_ urlString: String, headers: [String: String]) -> URLRequest {
        var r = URLRequest(url: URL(string: urlString)!)
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    func testRedirectStripsSecretsCrossHost() {
        let orig = URL(string: "https://files.example.com/a")!
        let redirect = request("https://attacker.example.net/collect",
                               headers: ["Authorization": "Basic x", "Cookie": "s=1",
                                         "Referer": "https://files.example.com/",
                                         "X-Api-Key": "secret", "User-Agent": "Goel"])
        let out = RedirectSanitizer.sanitize(redirect, originalURL: orig)
        XCTAssertNil(out.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(out.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(out.value(forHTTPHeaderField: "Referer"))
        XCTAssertNil(out.value(forHTTPHeaderField: "X-Api-Key"), "custom auth headers must be stripped too")
        XCTAssertEqual(out.value(forHTTPHeaderField: "User-Agent"), "Goel", "transport headers are kept")
    }

    func testRedirectKeepsHeadersSameHost() {
        let orig = URL(string: "https://cdn.example.com/a")!
        let redirect = request("https://cdn.example.com/b",
                               headers: ["Authorization": "Basic x", "X-Api-Key": "secret"])
        let out = RedirectSanitizer.sanitize(redirect, originalURL: orig)
        XCTAssertEqual(out.value(forHTTPHeaderField: "Authorization"), "Basic x")
        XCTAssertEqual(out.value(forHTTPHeaderField: "X-Api-Key"), "secret")
    }

    func testRedirectStripsOnHTTPSDowngradeSameHost() {
        let orig = URL(string: "https://example.com/a")!
        let redirect = request("http://example.com/a", headers: ["Authorization": "Basic x"])
        let out = RedirectSanitizer.sanitize(redirect, originalURL: orig)
        XCTAssertNil(out.value(forHTTPHeaderField: "Authorization"), "https→http downgrade strips secrets")
    }

    func testRedirectKeepsHeadersOnSameHostPlainHTTPHop() {
        // Same-host http→http is not a downgrade; stripping here saves a login page instead of the file.
        let orig = URL(string: "http://files.corp.local/download?id=5")!
        let redirect = request("http://files.corp.local/store/report.zip",
                               headers: ["Cookie": "session=1", "Authorization": "Basic x"])
        let out = RedirectSanitizer.sanitize(redirect, originalURL: orig)
        XCTAssertEqual(out.value(forHTTPHeaderField: "Cookie"), "session=1")
        XCTAssertEqual(out.value(forHTTPHeaderField: "Authorization"), "Basic x")
    }

    func testRedirectStripsOnCrossHostPlainHTTPHop() {
        // Plain http is forgiven only within one host: a cross-host hop still leaks the secret.
        let orig = URL(string: "http://files.corp.local/a")!
        let redirect = request("http://attacker.example.net/collect",
                               headers: ["Cookie": "session=1"])
        let out = RedirectSanitizer.sanitize(redirect, originalURL: orig)
        XCTAssertNil(out.value(forHTTPHeaderField: "Cookie"))
    }

    func testPasswordHashIsV2AndVerifies() {
        let hash = RemotePassword.hash("correct horse")
        XCTAssertTrue(hash.hasPrefix("v2$"), "new hashes use PBKDF2 (v2)")
        XCTAssertTrue(RemotePassword.verify("correct horse", against: hash))
        XCTAssertFalse(RemotePassword.verify("wrong", against: hash))
        XCTAssertEqual(RemotePassword.hash(""), "", "empty password → empty hash")
    }

    func testDistinctSaltsPerHash() {
        XCTAssertNotEqual(RemotePassword.hash("same"), RemotePassword.hash("same"),
                          "each hash uses a fresh random salt")
    }

    func testAutoFetchBlocksLinkLocalAndNonWeb() {
        XCTAssertFalse(NetworkGuard.isAllowedAutoTarget(URL(string: "http://169.254.169.254/latest/meta-data/")!))
        XCTAssertFalse(NetworkGuard.isAllowedAutoTarget(URL(string: "http://[fe80::1]/x")!))
        XCTAssertFalse(NetworkGuard.isAllowedAutoTarget(URL(string: "file:///etc/passwd")!))
        XCTAssertTrue(NetworkGuard.isAllowedAutoTarget(URL(string: "https://example.com/feed.xml")!))
        // A self-hosted LAN server is deliberately still allowed.
        XCTAssertTrue(NetworkGuard.isAllowedAutoTarget(URL(string: "http://192.168.1.10/feed")!))
    }

    func testExportSanitizedSettingsStripsSecrets() {
        var s = AppSettings()
        s.remoteToken = "tok-abc"
        s.remotePasswordHash = "v2$aa$bb"
        let out = DownloadManager.exportSanitizedSettings(s)
        XCTAssertEqual(out.remoteToken, "")
        XCTAssertEqual(out.remotePasswordHash, "")
    }

    func testProcessSafetyRejectsInterpretersAndRelative() {
        XCTAssertFalse(ProcessSafety.isSafeExecutable("/bin/sh"))
        XCTAssertFalse(ProcessSafety.isSafeExecutable("ffmpeg"), "relative $PATH name refused")
        XCTAssertFalse(ProcessSafety.isSafeExecutable(""), "empty refused")
        XCTAssertFalse(ProcessSafety.isSafeExecutable("/nonexistent/tool"))
        XCTAssertFalse(ProcessSafety.isSafeExecutable("/tmp"),
                       "a directory carries the execute bit but is not a program")
        XCTAssertFalse(ProcessSafety.isSafeExecutable("/usr/bin"))
        XCTAssertTrue(ProcessSafety.isSafeExecutable("/bin/ls"))
    }

    /// Homebrew installs ffmpeg as a symlink into ../Cellar, so refusing symlinks would break the
    /// commonest real install — but the directory check must not be dodgeable through one either.
    func testSymlinksAreFollowedToWhatTheyActuallyPointAt() throws {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("procsafety-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let toProgram = dir.appendingPathComponent("ffmpeg")
        let toDirectory = dir.appendingPathComponent("dirlink")
        try fm.createSymbolicLink(atPath: toProgram.path, withDestinationPath: "/bin/ls")
        try fm.createSymbolicLink(atPath: toDirectory.path, withDestinationPath: "/tmp")

        XCTAssertTrue(ProcessSafety.isSafeExecutable(toProgram.path),
                      "a symlink to a real program is how Homebrew ships ffmpeg")
        XCTAssertFalse(ProcessSafety.isSafeExecutable(toDirectory.path),
                       "a symlink must not launder a directory past the check")
    }
}
