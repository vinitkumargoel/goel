import XCTest
@testable import GoelCLI

final class DispatchTests: XCTestCase {

    // MARK: - URL shorthand detection

    func testDownloadSourcesAreRecognised() {
        for source in [
            "https://example.com/file.iso",
            "http://example.com/a?b=c",
            "HTTPS://EXAMPLE.COM/UPPER",
            "ftp://host/file.bin",
            "ftps://host/file.bin",
            "sftp://host/path/file.bin",
            "magnet:?xt=urn:btih:abcdef0123456789",
        ] {
            XCTAssertTrue(GoelCLI.looksLikeSource(source), source)
        }
    }

    /// Commands, paths and dangerous schemes must fall through to normal dispatch —
    /// the server-side allowlist is the authority, this is only routing.
    func testNonSourcesFallThroughToCommands() {
        for text in [
            "add", "list", "status", "help",
            "file.torrent", "./file.torrent", "/tmp/file.torrent",
            "file:///etc/passwd", "javascript:alert(1)",
            "example.com/no-scheme", "httpx://close-but-no",
        ] {
            XCTAssertFalse(GoelCLI.looksLikeSource(text), text)
        }
    }

    // MARK: - add-argument parsing

    func testAddDefaultsQueueAndReturn() throws {
        let options = try GoelCLI.parseAddArguments(["https://e/x.bin"], waitByDefault: false)
        XCTAssertEqual(options.urls, ["https://e/x.bin"])
        XCTAssertFalse(options.wait)
        XCTAssertFalse(options.json)
        XCTAssertNil(options.timeoutSeconds)
    }

    func testShorthandWaitsByDefaultAndDetachOptsOut() throws {
        let waiting = try GoelCLI.parseAddArguments(["https://e/x.bin"], waitByDefault: true)
        XCTAssertTrue(waiting.wait)
        let detached = try GoelCLI.parseAddArguments(["https://e/x.bin", "--detach"],
                                                     waitByDefault: true)
        XCTAssertFalse(detached.wait)
    }

    func testEveryFlagParses() throws {
        let options = try GoelCLI.parseAddArguments(
            ["https://e/x.bin", "--folder", "/srv/media", "--priority", "high",
             "--net", "single:eth0", "--wait", "--json", "--timeout", "90"],
            waitByDefault: false)
        XCTAssertEqual(options.folder, "/srv/media")
        XCTAssertEqual(options.priority, "high")
        XCTAssertEqual(options.network, "single:eth0")
        XCTAssertTrue(options.wait)
        XCTAssertTrue(options.json)
        XCTAssertEqual(options.timeoutSeconds, 90)
    }

    /// `goel <url> --paused` means "queue it, held" — the implied wait must drop away,
    /// because a paused download never finishes.
    func testPausedQuietlyCancelsTheImpliedWait() throws {
        let options = try GoelCLI.parseAddArguments(["https://e/x.bin", "--paused"],
                                                    waitByDefault: true)
        XCTAssertTrue(options.paused)
        XCTAssertFalse(options.wait)
    }

    func testPausedWithExplicitWaitIsAContradiction() {
        XCTAssertThrowsError(try GoelCLI.parseAddArguments(
            ["https://e/x.bin", "--paused", "--wait"], waitByDefault: false))
    }

    func testTimeoutRequiresWaiting() {
        XCTAssertThrowsError(try GoelCLI.parseAddArguments(
            ["https://e/x.bin", "--timeout", "5"], waitByDefault: false))
    }

    func testTimeoutRejectsNonNumbers() {
        XCTAssertThrowsError(try GoelCLI.parseAddArguments(
            ["https://e/x.bin", "--wait", "--timeout", "soon"], waitByDefault: false))
        XCTAssertThrowsError(try GoelCLI.parseAddArguments(
            ["https://e/x.bin", "--wait", "--timeout", "0"], waitByDefault: false))
    }

    func testUnknownFlagIsAUsageError() {
        XCTAssertThrowsError(try GoelCLI.parseAddArguments(
            ["https://e/x.bin", "--turbo"], waitByDefault: false))
    }

    func testBadNetworkSpecIsRefusedLocally() {
        XCTAssertThrowsError(try GoelCLI.parseAddArguments(
            ["https://e/x.bin", "--net", "single:"], waitByDefault: false))
    }

    // MARK: - progress line

    func testProgressLineCarriesNamePercentAndSpeed() throws {
        let json = """
        {"id":"A","name":"ubuntu.iso","status":"Downloading","statusToken":"downloading",
         "kind":"http","progress":0.62,"downSpeed":1048576,"doneBytes":0,
         "totalBytes":1000,"etaSeconds":42,"error":null}
        """
        let row = try JSONDecoder().decode(API.TaskRow.self, from: Data(json.utf8))
        let line = GoelCLI.ProgressLine.line(for: row)
        XCTAssertTrue(line.contains("ubuntu.iso"))
        XCTAssertTrue(line.contains("62%"))
        XCTAssertTrue(line.contains("MB/s"))
        XCTAssertTrue(line.contains("ETA"))
    }

    // MARK: - reporting hygiene

    /// The same URL twice in one `add` echoes the same task ID twice — the report
    /// must still describe one download, in queue order.
    func testFollowedIDsAreDeduplicatedInOrder() {
        XCTAssertEqual(GoelCLI.orderedUnique(["a", "b", "a", "c", "b"]), ["a", "b", "c"])
        XCTAssertEqual(GoelCLI.orderedUnique([]), [])
    }

    /// `goel web` must keep the token out of the opener's argv: it goes into a
    /// redirect file only this user can read.
    func testPortalLauncherIsPrivateAndCarriesTheLink() throws {
        let dir = NSTemporaryDirectory() + "goel-launcher-test-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let link = "http://127.0.0.1:1234/?token=secret"
        let file = try XCTUnwrap(GoelCLI.writePortalLauncher(link: link, directory: dir))
        XCTAssertTrue(try String(contentsOfFile: file, encoding: .utf8).contains(link))
        let mode = { (path: String) in
            (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]
                as? NSNumber)?.uint16Value
        }
        XCTAssertEqual(mode(file), 0o600)
        XCTAssertEqual(mode(dir), 0o700)
    }

    /// Server-chosen names reach the terminal; ANSI/OSC escapes in them must not.
    func testRemoteTextIsStrippedOfTerminalEscapes() {
        XCTAssertEqual(Out.safe("\u{1B}]0;pwned\u{07}file.iso"), "]0;pwnedfile.iso")
        XCTAssertEqual(Out.safe("a\u{1B}[31mred\u{1B}[0m"), "a[31mred[0m")
        XCTAssertEqual(Out.safe("tab\there\nline\u{7F}del\u{9B}csi"), "tabherelinedelcsi")
        XCTAssertEqual(Out.safe("plain — файл名前.iso"), "plain — файл名前.iso")
    }
}
