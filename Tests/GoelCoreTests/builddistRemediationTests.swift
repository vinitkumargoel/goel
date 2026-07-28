// macOS-only: these gates need vtool, codesign and hdiutil, which have no Linux equivalent.
#if !os(Linux)
import XCTest

final class BuildDistRemediationTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func read(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    @discardableResult
    private func run(_ relativePath: String, _ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [repoRoot.appendingPathComponent(relativePath).path] + arguments
        process.currentDirectoryURL = repoRoot
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func testMinOSComparatorSelfTestPasses() throws {
        let (status, output) = try run("Scripts/check_min_os.sh", ["--self-test"])
        XCTAssertEqual(status, 0, "check_min_os.sh --self-test failed:\n\(output)")
        XCTAssertTrue(output.contains("self-test passed"), output)
        XCTAssertFalse(output.contains("FAIL"), output)
    }

    func testMinOSGateRejectsABundleThatOutRunsItsMinimumSystemVersion() throws {
        let fixture = try makeFixtureBundle(minimumSystemVersion: "10.0")
        defer { try? FileManager.default.removeItem(at: fixture) }

        let (status, output) = try run("Scripts/check_min_os.sh", [fixture.path])
        XCTAssertNotEqual(status, 0, "the gate accepted an unlaunchable bundle:\n\(output)")
        XCTAssertTrue(output.contains("requires macOS"), output)
    }

    func testMinOSGateAcceptsAnHonestlyLabelledBundle() throws {
        let fixture = try makeFixtureBundle(minimumSystemVersion: "14.0")
        defer { try? FileManager.default.removeItem(at: fixture) }

        let (status, output) = try run("Scripts/check_min_os.sh", [fixture.path])
        XCTAssertEqual(status, 0, "the gate rejected a correct bundle:\n\(output)")
    }

    func testMinOSGateRequiresTheTCCPurposeStrings() throws {
        let fixture = try makeFixtureBundle(minimumSystemVersion: "14.0",
                                            purposeStrings: false)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let (status, output) = try run("Scripts/check_min_os.sh", [fixture.path])
        XCTAssertNotEqual(status, 0, "a bundle with no purpose strings was accepted:\n\(output)")
        XCTAssertTrue(output.contains("NSAppleEventsUsageDescription"), output)
    }

    private func makeFixtureBundle(minimumSystemVersion: String,
                                   purposeStrings: Bool = true) throws -> URL {
        let fm = FileManager.default
        let bundle = fm.temporaryDirectory
            .appendingPathComponent("GoelMinOSFixture-\(UUID().uuidString).app")
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "/bin/ls"),
                        to: macOS.appendingPathComponent("Fixture"))

        var keys = """
                <key>CFBundleExecutable</key>
                <string>Fixture</string>
                <key>LSMinimumSystemVersion</key>
                <string>\(minimumSystemVersion)</string>
        """
        if purposeStrings {
            keys += """

                <key>NSAppleEventsUsageDescription</key>
                <string>Fixture asks System Events to shut down.</string>
                <key>NSLocalNetworkUsageDescription</key>
                <string>Fixture serves a portal on your network.</string>
        """
        }
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \(keys)
        </dict>
        </plist>

        """
        try plist.write(to: bundle.appendingPathComponent("Contents/Info.plist"),
                        atomically: true, encoding: .utf8)
        return bundle
    }

    /// One gate the packaging scripts must carry. `present: false` pins a regression that must stay fixed.
    private struct Gate {
        let file: String, needle: String, present: Bool, why: String
        init(_ file: String, _ needle: String, present: Bool = true, _ why: String) {
            self.file = file; self.needle = needle; self.present = present; self.why = why
        }
    }

    func testPackagingScriptsCarryEveryGateTheyAreTrustedToEnforce() throws {
        let build = "Scripts/build_app.sh"
        let gates: [Gate] = [
            // Info.plist purpose strings: a missing key makes the packaged app fail the TCC prompt silently.
            Gate(build, "NSAppleEventsUsageDescription", "build_app.sh no longer declares it"),
            Gate(build, "NSLocalNetworkUsageDescription", "build_app.sh no longer declares it"),
            Gate(build, "NSDownloadsFolderUsageDescription", "build_app.sh no longer declares it"),
            Gate(build, "NSDesktopFolderUsageDescription", "build_app.sh no longer declares it"),
            Gate(build, "NSDocumentsFolderUsageDescription", "build_app.sh no longer declares it"),
            Gate(build, "NSRemovableVolumesUsageDescription", "build_app.sh no longer declares it"),
            Gate(build, "NSNetworkVolumesUsageDescription", "build_app.sh no longer declares it"),

            Gate(build, "NSBonjourServices",
                 "NSBonjourServices is required before macOS will advertise the portal"),
            Gate(build, "<string>_http._tcp</string>",
                 "Info.plist must list the exact service type the listener registers"),
            Gate("Sources/GoelCore/Remote/RemoteControlServer.swift", "\"_http._tcp\"",
                 "the listener no longer advertises _http._tcp"),

            Gate(build, "NSAppTransportSecurity",
                 "packaged builds cannot fetch http:// URLs without an ATS declaration"),
            Gate("Sources/GoelCore/Ports/NetworkGuard.swift", "scheme == \"http\" || scheme == \"https\"",
                 "NetworkGuard no longer permits http — the ATS exception should go too"),

            Gate(build, "grep '^Developer ID Application:'",
                 "the release path must filter for Developer ID Application identities"),
            Gate(build, "GOEL_RELEASE", "there is no longer a distinct release mode"),
            Gate(build, "no 'Developer ID Application' identity is installed",
                 "a release with no distribution certificate must fail, not fall back"),

            Gate(build, "codesign --verify --strict --deep \"$APP\" && echo", present: false,
                 "a failing verify must abort the build, not be swallowed by set -e"),
            Gate(build, "if ! codesign --verify --strict --deep \"$APP\"; then",
                 "signature verification must be checked explicitly"),

            Gate(build, "spctl -a -vvv -t exec", "nothing runs the Gatekeeper assessment"),
            Gate(build, "source=Notarized Developer ID",
                 "a locally-accepted unnotarized bundle must not count as passing"),
            Gate(build, "xcrun stapler validate",
                 "the notarization ticket must be confirmed as stapled"),

            Gate(build, "if [ \"$DISTRIBUTABLE\" = 1 ]; then\n  VERSION=",
                 "packaging must be gated on the build actually being distributable"),
            Gate(build, "no distributable archive emitted",
                 "a dev build must say out loud that it produced nothing shippable"),

            Gate(build, "\"dist/$APP_NAME.zip\"", present: false,
                 "the pre-staple zip must not be written into dist/"),
            Gate(build, "$SCRATCH/$APP_NAME.zip",
                 "the notarization payload belongs in a scratch directory"),

            Gate("Scripts/make_dmg.sh", "xcrun stapler validate \"$APP\"",
                 "a DMG must not be built around an unnotarized app"),
            Gate("Scripts/make_dmg.sh", "codesign --force --timestamp -s \"$CODESIGN_IDENTITY\" \"$DMG\"",
                 "the disk image itself must be signed"),
            Gate("Scripts/make_dmg.sh", "spctl -a -t open --context context:primary-signature",
                 "the disk image must pass the assessment a double-click performs"),

            Gate("Scripts/bundle_dylibs.sh",
                 "warning: codesign --verify --deep --strict reported issues", present: false,
                 "a broken seal must fail the build, not warn"),
            Gate("Scripts/bundle_dylibs.sh", "error: bundle is not validly signed after vendoring",
                 "the verification failure must be terminal"),
            Gate("Scripts/bundle_dylibs.sh", "<string>1.0.2</string>", present: false,
                 "the resource-bundle version must not be a literal"),
            Gate("Scripts/bundle_dylibs.sh", "<string>$short</string>",
                 "the resource bundle must take its version from the app's Info.plist"),

            // yt-dlp carries disable-library-validation / allow-jit, so its download must be digest-pinned.
            Gate("Scripts/fetch_ytdlp.sh", "YTDLP_SHA256", "the yt-dlp asset must be pinned to a digest"),
            Gate("Scripts/fetch_ytdlp.sh", "yt-dlp checksum mismatch", "a digest mismatch must be refused"),
            Gate("Scripts/fetch_ytdlp.sh", "YTDLP_VERSION=latest cannot be verified",
                 "a moving tag has no digest and must not be accepted"),
            Gate("Scripts/fetch_ytdlp.sh", "warning: bundled yt-dlp", present: false,
                 "an unusable yt-dlp must not be downgraded to a warning"),
            Gate("Scripts/fetch_ytdlp.sh", "does not include the target arch",
                 "the arch check must compare against the TARGET, not the host"),
            Gate("Scripts/fetch_ytdlp.sh", "YTDLP_ARCH",
                 "a cross-build must be able to state the arch it is building for"),

            Gate("Scripts/linux/build-sqlite.sh", "SQLITE_SHA256", "the amalgamation must be pinned"),
            Gate("Scripts/linux/build-sqlite.sh", "sha256sum -c -", "the digest must be verified"),
            Gate("Scripts/linux/build-sqlite.sh", "curl -s https://sqlite.org/download.html", present: false,
                 "the unpinned, unchecked scrape must not be the default path"),

            Gate(build, "[ -f LICENSE ] && cp LICENSE", present: false,
                 "licence files must not be copied on a best-effort test"),
            Gate(build, "it must ride inside the bundle", "a missing licence file must fail the build"),
            Gate(build, "BUNDLE_YTDLP:-1",
                 "shipping without yt-dlp must remain possible for the mere-aggregation argument to hold"),
            Gate(build, "git rev-parse --is-shallow-repository",
                 "the shallow-clone case must be detected and named"),
            Gate(build, "would look OLDER", "a regressing CFBundleVersion must be refused"),
            Gate(build, "GOEL_NO_UPDATER",
                 "shipping a release with no updater must be an explicit decision"),
            Gate(build, "no update path at all", "the failure must say what is actually wrong"),

            Gate("THIRD-PARTY-NOTICES.md", "mutagen",
                 "the GPL-2.0-or-later component inside yt-dlp must be named"),
            Gate("THIRD-PARTY-NOTICES.md", "other permissively-licensed components", present: false,
                 "yt-dlp's embedded components are not all permissive"),
            Gate("THIRD-PARTY-NOTICES.md", "GNU GENERAL PUBLIC LICENSE",
                 "the GPL-2.0 text itself must be present, not merely linked"),
            Gate("THIRD-PARTY-NOTICES.md", "Version 2, June 1991", "the reproduced licence must be version 2"),
            Gate("THIRD-PARTY-NOTICES.md", "Appendix B",
                 "the GPL text must be reachable from the table of obligations"),
            Gate("THIRD-PARTY-NOTICES.md", "mere aggregation",
                 "the basis for bundling a GPL'd executable must be stated"),

            Gate("Scripts/linux/package_daemon.sh", "libXCTest\\.so|libTesting\\.so",
                 "test-only runtime libraries must be excluded from the tarball"),
            Gate("Scripts/linux/package_daemon.sh", "THIRD-PARTY-NOTICES.md",
                 "the tarball must carry the third-party notices"),
            Gate("Scripts/linux/package_daemon.sh", "SWIFT-RUNTIME-",
                 "the Swift runtime's own Apache-2.0 notice must travel with its .so files"),

            Gate(".github/workflows/ci.yml", "runs-on: macos-14",
                 "the runner must pour Homebrew bottles targeting the deployment target"),
            Gate(".github/workflows/ci.yml", "fetch-depth: 0",
                 "a shallow clone collapses the git-derived CFBundleVersion to 1"),
            Gate(".github/workflows/ci.yml", "Scripts/check_min_os.sh --self-test",
                 "the comparator self-test must run on every pull request"),
            Gate(".github/workflows/ci.yml", "which was built for newer version",
                 "CI must fail on the linker's deployment-target warning"),
            Gate(".github/workflows/ci.yml", "swift test", "CI must run the test suite"),
        ]

        var cache: [String: String] = [:]
        for gate in gates {
            let source: String
            if let hit = cache[gate.file] {
                source = hit
            } else {
                source = try read(gate.file)
                cache[gate.file] = source
            }
            XCTAssertEqual(source.contains(gate.needle), gate.present,
                           "\(gate.file): \(gate.why)")
        }

        for file in ["LICENSE", "LICENSE-COMMERCIAL.md", "TRADEMARK.md", "THIRD-PARTY-NOTICES.md"] {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: repoRoot.appendingPathComponent(file).path),
                          "\(file) is required by the packaging step")
        }
    }

    /// The digest must be checked before unzip/tar runs, or an archive parser is pointed at unverified input.
    func testFFmpegArchiveIsVerifiedBeforeItIsUnpacked() throws {
        let script = try read("Scripts/fetch_ffmpeg.sh")
        guard let verifyIndex = script.range(of: "ACTUAL=\"$(sha256_of \"$TMP\")\""),
              let unpackIndex = script.range(of: "unzip -q -o \"$TMP\"") else {
            return XCTFail("fetch_ffmpeg.sh no longer has the download/verify/unpack sequence")
        }
        XCTAssertLessThan(verifyIndex.lowerBound, unpackIndex.lowerBound,
                          "the digest must be checked before the archive is opened")
    }
}

#endif
