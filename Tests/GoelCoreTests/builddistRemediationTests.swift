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

    func testGeneratedInfoPlistCarriesEveryPurposeStringTheAppNeeds() throws {
        let script = try read("Scripts/build_app.sh")
        for key in ["NSAppleEventsUsageDescription",
                    "NSLocalNetworkUsageDescription",
                    "NSDownloadsFolderUsageDescription",
                    "NSDesktopFolderUsageDescription",
                    "NSDocumentsFolderUsageDescription",
                    "NSRemovableVolumesUsageDescription",
                    "NSNetworkVolumesUsageDescription"] {
            XCTAssertTrue(script.contains(key), "build_app.sh no longer declares \(key)")
        }
    }

    func testBonjourServiceTypeMatchesTheListener() throws {
        let script = try read("Scripts/build_app.sh")
        let server = try read("Sources/GoelCore/Remote/RemoteControlServer.swift")
        XCTAssertTrue(script.contains("NSBonjourServices"),
                      "NSBonjourServices is required before macOS will advertise the portal")
        XCTAssertTrue(server.contains("\"_http._tcp\""),
                      "the listener no longer advertises _http._tcp")
        XCTAssertTrue(script.contains("<string>_http._tcp</string>"),
                      "Info.plist must list the exact service type the listener registers")
    }

    func testGeneratedInfoPlistPermitsThePlainHTTPDownloadsNetworkGuardAllows() throws {
        let script = try read("Scripts/build_app.sh")
        XCTAssertTrue(script.contains("NSAppTransportSecurity"),
                      "packaged builds cannot fetch http:// URLs without an ATS declaration")
        let guardSource = try read("Sources/GoelCore/Ports/NetworkGuard.swift")
        XCTAssertTrue(guardSource.contains("scheme == \"http\" || scheme == \"https\""),
                      "NetworkGuard no longer permits http — the ATS exception should go too")
    }

    func testReleaseSigningRequiresADeveloperIDIdentity() throws {
        let script = try read("Scripts/build_app.sh")
        XCTAssertTrue(script.contains("grep '^Developer ID Application:'"),
                      "the release path must filter for Developer ID Application identities")
        XCTAssertTrue(script.contains("GOEL_RELEASE"),
                      "there is no longer a distinct release mode")
        XCTAssertTrue(script.contains("no 'Developer ID Application' identity is installed"),
                      "a release with no distribution certificate must fail, not fall back")
    }

    func testSignatureVerificationFailureAbortsTheBuild() throws {
        let script = try read("Scripts/build_app.sh")
        XCTAssertFalse(script.contains("codesign --verify --strict --deep \"$APP\" && echo"),
                       "a failing verify must abort the build, not be swallowed by set -e")
        XCTAssertTrue(script.contains("if ! codesign --verify --strict --deep \"$APP\"; then"),
                      "signature verification must be checked explicitly")
    }

    func testGatekeeperIsAssessedBeforeAnythingIsCalledADistributable() throws {
        let script = try read("Scripts/build_app.sh")
        XCTAssertTrue(script.contains("spctl -a -vvv -t exec"),
                      "nothing runs the Gatekeeper assessment")
        XCTAssertTrue(script.contains("source=Notarized Developer ID"),
                      "a locally-accepted unnotarized bundle must not count as passing")
        XCTAssertTrue(script.contains("xcrun stapler validate"),
                      "the notarization ticket must be confirmed as stapled")
    }

    func testOnlyADistributableBuildEmitsAReleaseArchive() throws {
        let script = try read("Scripts/build_app.sh")
        XCTAssertTrue(script.contains("if [ \"$DISTRIBUTABLE\" = 1 ]; then\n  VERSION="),
                      "packaging must be gated on the build actually being distributable")
        XCTAssertTrue(script.contains("no distributable archive emitted"),
                      "a dev build must say out loud that it produced nothing shippable")
    }

    func testNotarizationPayloadIsNotLeftInTheDistDirectory() throws {
        let script = try read("Scripts/build_app.sh")
        XCTAssertFalse(script.contains("\"dist/$APP_NAME.zip\""),
                       "the pre-staple zip must not be written into dist/")
        XCTAssertTrue(script.contains("$SCRATCH/$APP_NAME.zip"),
                      "the notarization payload belongs in a scratch directory")
    }

    func testDMGIsGatedSignedAndAssessed() throws {
        let script = try read("Scripts/make_dmg.sh")
        XCTAssertTrue(script.contains("xcrun stapler validate \"$APP\""),
                      "a DMG must not be built around an unnotarized app")
        XCTAssertTrue(script.contains("codesign --force --timestamp -s \"$CODESIGN_IDENTITY\" \"$DMG\""),
                      "the disk image itself must be signed")
        XCTAssertTrue(script.contains("spctl -a -t open --context context:primary-signature"),
                      "the disk image must pass the assessment a double-click performs")
    }

    func testVendoringFailsClosedOnABrokenSignature() throws {
        let script = try read("Scripts/bundle_dylibs.sh")
        XCTAssertFalse(script.contains("warning: codesign --verify --deep --strict reported issues"),
                       "a broken seal must fail the build, not warn")
        XCTAssertTrue(script.contains("error: bundle is not validly signed after vendoring"),
                      "the verification failure must be terminal")
    }

    func testSynthesizedResourceBundlePlistTracksTheAppVersion() throws {
        let script = try read("Scripts/bundle_dylibs.sh")
        XCTAssertFalse(script.contains("<string>1.0.2</string>"),
                       "the resource-bundle version must not be a literal")
        XCTAssertTrue(script.contains("<string>$short</string>"),
                      "the resource bundle must take its version from the app's Info.plist")
    }

    /// yt-dlp carries the disable-library-validation / allow-jit entitlements, so its download must be digest-pinned.
    func testYtDlpDownloadIsPinnedAndVerified() throws {
        let script = try read("Scripts/fetch_ytdlp.sh")
        XCTAssertTrue(script.contains("YTDLP_SHA256"),
                      "the yt-dlp asset must be pinned to a digest")
        XCTAssertTrue(script.contains("yt-dlp checksum mismatch"),
                      "a digest mismatch must be refused")
        XCTAssertTrue(script.contains("YTDLP_VERSION=latest cannot be verified"),
                      "a moving tag has no digest and must not be accepted")
    }

    func testYtDlpArchAndSmokeTestFailuresAreTerminal() throws {
        let script = try read("Scripts/fetch_ytdlp.sh")
        XCTAssertFalse(script.contains("warning: bundled yt-dlp"),
                       "an unusable yt-dlp must not be downgraded to a warning")
        XCTAssertTrue(script.contains("does not include the target arch"),
                      "the arch check must compare against the TARGET, not the host")
        XCTAssertTrue(script.contains("YTDLP_ARCH"),
                      "a cross-build must be able to state the arch it is building for")
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

    func testSQLiteAmalgamationIsPinnedAndVerified() throws {
        let script = try read("Scripts/linux/build-sqlite.sh")
        XCTAssertTrue(script.contains("SQLITE_SHA256"), "the amalgamation must be pinned")
        XCTAssertTrue(script.contains("sha256sum -c -"), "the digest must be verified")
        XCTAssertFalse(script.contains("curl -s https://sqlite.org/download.html"),
                       "the unpinned, unchecked scrape must not be the default path")
    }

    func testBundledLicenceFilesAreRequiredNotBestEffort() throws {
        let script = try read("Scripts/build_app.sh")
        XCTAssertFalse(script.contains("[ -f LICENSE ] && cp LICENSE"),
                       "licence files must not be copied on a best-effort test")
        XCTAssertTrue(script.contains("it must ride inside the bundle"),
                      "a missing licence file must fail the build")
        for file in ["LICENSE", "LICENSE-COMMERCIAL.md", "TRADEMARK.md", "THIRD-PARTY-NOTICES.md"] {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: repoRoot.appendingPathComponent(file).path),
                          "\(file) is required by the packaging step")
        }
    }

    func testGPLTextAccompaniesTheBundledYtDlp() throws {
        let notices = try read("THIRD-PARTY-NOTICES.md")
        XCTAssertTrue(notices.contains("mutagen"),
                      "the GPL-2.0-or-later component inside yt-dlp must be named")
        XCTAssertFalse(notices.contains("other permissively-licensed components"),
                       "yt-dlp's embedded components are not all permissive")
        XCTAssertTrue(notices.contains("GNU GENERAL PUBLIC LICENSE"),
                      "the GPL-2.0 text itself must be present, not merely linked")
        XCTAssertTrue(notices.contains("Version 2, June 1991"),
                      "the reproduced licence must be version 2")
        XCTAssertTrue(notices.contains("Appendix B"),
                      "the GPL text must be reachable from the table of obligations")
    }

    func testMereAggregationArgumentIsRecordedAndStillTrue() throws {
        let notices = try read("THIRD-PARTY-NOTICES.md")
        XCTAssertTrue(notices.contains("mere aggregation"),
                      "the basis for bundling a GPL'd executable must be stated")
        let script = try read("Scripts/build_app.sh")
        XCTAssertTrue(script.contains("BUNDLE_YTDLP:-1"),
                      "shipping without yt-dlp must remain possible for the argument to hold")
    }

    func testLinuxDaemonHasAPackagingScriptThatShipsLicencesAndNoTestLibraries() throws {
        let script = try read("Scripts/linux/package_daemon.sh")
        XCTAssertTrue(script.contains("libXCTest\\.so|libTesting\\.so"),
                      "test-only runtime libraries must be excluded from the tarball")
        XCTAssertTrue(script.contains("THIRD-PARTY-NOTICES.md"),
                      "the tarball must carry the third-party notices")
        XCTAssertTrue(script.contains("SWIFT-RUNTIME-"),
                      "the Swift runtime's own Apache-2.0 notice must travel with its .so files")
    }

    func testCIRunsTheGatesOnAMatchingRunner() throws {
        let workflow = try read(".github/workflows/ci.yml")
        XCTAssertTrue(workflow.contains("runs-on: macos-14"),
                      "the runner must pour Homebrew bottles targeting the deployment target")
        XCTAssertTrue(workflow.contains("fetch-depth: 0"),
                      "a shallow clone collapses the git-derived CFBundleVersion to 1")
        XCTAssertTrue(workflow.contains("Scripts/check_min_os.sh --self-test"),
                      "the comparator self-test must run on every pull request")
        XCTAssertTrue(workflow.contains("which was built for newer version"),
                      "CI must fail on the linker's deployment-target warning")
        XCTAssertTrue(workflow.contains("swift test"), "CI must run the test suite")
    }

    func testShallowCloneCannotStampARegressingBundleVersion() throws {
        let script = try read("Scripts/build_app.sh")
        XCTAssertTrue(script.contains("git rev-parse --is-shallow-repository"),
                      "the shallow-clone case must be detected and named")
        XCTAssertTrue(script.contains("would look OLDER"),
                      "a regressing CFBundleVersion must be refused")
    }

    func testReleaseWithoutAnUpdaterMustBeAcknowledgedExplicitly() throws {
        let script = try read("Scripts/build_app.sh")
        XCTAssertTrue(script.contains("GOEL_NO_UPDATER"),
                      "shipping a release with no updater must be an explicit decision")
        XCTAssertTrue(script.contains("no update path at all"),
                      "the failure must say what is actually wrong")
    }
}

#endif
