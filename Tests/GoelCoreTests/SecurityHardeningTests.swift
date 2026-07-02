import XCTest
@testable import GoelCore

/// Regression tests for the security-audit hardening pass: credential stripping,
/// path containment, cross-host header stripping, the PBKDF2 KDF upgrade, SSRF
/// target filtering, export secret-stripping, and external-tool vetting.
final class SecurityHardeningTests: XCTestCase {

    // MARK: H4 — FTP inline credentials are stripped from the persisted locator

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

    // MARK: H1 / #19 — path containment

    func testIsContainedRejectsTraversalAndAbsolute() {
        let root = "/Users/me/Downloads"
        XCTAssertTrue(PathSafety.isContained("/Users/me/Downloads/movie.mp4", within: root))
        XCTAssertTrue(PathSafety.isContained(root, within: root))
        XCTAssertFalse(PathSafety.isContained("/Users/me/Downloads/../../.zshrc", within: root))
        XCTAssertFalse(PathSafety.isContained("/etc/cron.d/x", within: root))
        XCTAssertFalse(PathSafety.isContained("/Users/me/DownloadsEvil/x", within: root),
                       "prefix match must be on a path boundary, not a string prefix")
    }

    func testPrimaryFilePathRejectsEscapingTorrentEntry() {
        let dir = NSTemporaryDirectory()
        let files = [
            TransferFile(id: 0, path: "../../../../etc/passwd", length: 1_000_000),
            TransferFile(id: 1, path: "movie.mp4", length: 10),
        ]
        let task = DownloadTask(source: .magnet("magnet:?xt=urn:btih:abc"),
                                name: "t", saveDirectory: dir, files: files)
        // Largest wanted file declares a traversing path → falls back to savePath,
        // never a path outside the save directory.
        XCTAssertTrue(PathSafety.isContained(task.primaryFilePath, within: dir)
                        || task.primaryFilePath == task.savePath)
        XCTAssertFalse(task.primaryFilePath.contains("/etc/passwd"))
    }

    // MARK: H3 — cross-host redirect header stripping

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

    // MARK: #21 — PBKDF2 KDF upgrade (v2) with legacy (v1) verification

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

    // MARK: #17 — SSRF auto-fetch target filtering

    func testAutoFetchBlocksLinkLocalAndNonWeb() {
        XCTAssertFalse(NetworkGuard.isAllowedAutoTarget(URL(string: "http://169.254.169.254/latest/meta-data/")!))
        XCTAssertFalse(NetworkGuard.isAllowedAutoTarget(URL(string: "http://[fe80::1]/x")!))
        XCTAssertFalse(NetworkGuard.isAllowedAutoTarget(URL(string: "file:///etc/passwd")!))
        XCTAssertTrue(NetworkGuard.isAllowedAutoTarget(URL(string: "https://example.com/feed.xml")!))
        // A self-hosted LAN server is deliberately still allowed.
        XCTAssertTrue(NetworkGuard.isAllowedAutoTarget(URL(string: "http://192.168.1.10/feed")!))
    }

    // MARK: #14 — export strips secrets

    func testExportSanitizedSettingsStripsSecrets() {
        var s = AppSettings()
        s.remoteToken = "tok-abc"
        s.remotePasswordHash = "v2$aa$bb"
        let out = DownloadManager.exportSanitizedSettings(s)
        XCTAssertEqual(out.remoteToken, "")
        XCTAssertEqual(out.remotePasswordHash, "")
    }

    // MARK: #18 — external-tool vetting

    func testProcessSafetyRejectsInterpretersAndRelative() {
        XCTAssertFalse(ProcessSafety.isSafeExecutable("/bin/sh"))
        XCTAssertFalse(ProcessSafety.isSafeExecutable("ffmpeg"), "relative $PATH name refused")
        XCTAssertFalse(ProcessSafety.isSafeExecutable(""), "empty refused")
        XCTAssertFalse(ProcessSafety.isSafeExecutable("/nonexistent/tool"))
        // A real absolute executable present on every macOS/Linux host passes.
        XCTAssertTrue(ProcessSafety.isSafeExecutable("/bin/ls"))
    }
}
