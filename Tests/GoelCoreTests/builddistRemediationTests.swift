// Exercises Scripts/check_min_os.sh and the app-bundle gates, which need vtool,
// codesign and hdiutil — macOS-only tooling with no Linux equivalent.
#if !os(Linux)
import XCTest

/// Regression tests for the `Scripts/` build/signing/distribution logic — each gate here has failed
/// once with the build reporting success. `#filePath` locates the repo root wherever the binary runs.
final class BuildDistRemediationTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GoelCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    private func read(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// Run a repo script and return (exit status, combined output).
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

    // MARK: - The deployment-target gate

    /// The comparator is the whole minos gate and must order versions numerically: as strings "10.0"
    /// looks older than "9.0" and "14.10" older than "14.2", passing a bundle dyld refuses to launch.
    func testMinOSComparatorSelfTestPasses() throws {
        let (status, output) = try run("Scripts/check_min_os.sh", ["--self-test"])
        XCTAssertEqual(status, 0, "check_min_os.sh --self-test failed:\n\(output)")
        XCTAssertTrue(output.contains("self-test passed"), output)
        XCTAssertFalse(output.contains("FAIL"), output)
    }

    /// A bundle whose Mach-Os need a newer macOS than its LSMinimumSystemVersion must fail and name
    /// every offender — fixing them one round-trip at a time is how the gate gets disabled.
    func testMinOSGateRejectsABundleThatOutRunsItsMinimumSystemVersion() throws {
        let fixture = try makeFixtureBundle(minimumSystemVersion: "10.0")
        defer { try? FileManager.default.removeItem(at: fixture) }

        let (status, output) = try run("Scripts/check_min_os.sh", [fixture.path])
        XCTAssertNotEqual(status, 0, "the gate accepted an unlaunchable bundle:\n\(output)")
        XCTAssertTrue(output.contains("requires macOS"), output)
    }

    /// The same bundle, honestly labelled, must pass — a gate that fails
    /// everything is not a gate.
    func testMinOSGateAcceptsAnHonestlyLabelledBundle() throws {
        let fixture = try makeFixtureBundle(minimumSystemVersion: "14.0")
        defer { try? FileManager.default.removeItem(at: fixture) }

        let (status, output) = try run("Scripts/check_min_os.sh", [fixture.path])
        XCTAssertEqual(status, 0, "the gate rejected a correct bundle:\n\(output)")
    }

    /// Purpose strings are checked over the assembled bundle: a missing one is a runtime kill (Apple
    /// events) or silently dropped traffic (local network), never a build error.
    func testMinOSGateRequiresTheTCCPurposeStrings() throws {
        let fixture = try makeFixtureBundle(minimumSystemVersion: "14.0",
                                            purposeStrings: false)
        defer { try? FileManager.default.removeItem(at: fixture) }

        let (status, output) = try run("Scripts/check_min_os.sh", [fixture.path])
        XCTAssertNotEqual(status, 0, "a bundle with no purpose strings was accepted:\n\(output)")
        XCTAssertTrue(output.contains("NSAppleEventsUsageDescription"), output)
    }

    /// A `.app` with a real Mach-O and an Info.plist claiming `minimumSystemVersion`. `/bin/ls` targets
    /// well above 10.0 and below anything current — exactly the shape of the defect being guarded.
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

    // MARK: - Info.plist assembly

    /// macOS kills a process sending an Apple event with no NSAppleEventsUsageDescription — the "shut
    /// down when downloads finish" drain used to kill the app instead of the Mac.
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

    /// The advertised Bonjour service type must match the one RemoteControlServer registers, or macOS
    /// drops the advertisement without a word and the portal never appears on other devices.
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

    /// Without an ATS exception every plain-http transfer in a packaged build fails with -1022 against
    /// a URL that works in curl. NetworkGuard, not ATS, is what restricts the schemes.
    func testGeneratedInfoPlistPermitsThePlainHTTPDownloadsNetworkGuardAllows() throws {
        let script = try read("Scripts/build_app.sh")
        XCTAssertTrue(script.contains("NSAppTransportSecurity"),
                      "packaged builds cannot fetch http:// URLs without an ATS declaration")
        let guardSource = try read("Sources/GoelCore/Ports/NetworkGuard.swift")
        XCTAssertTrue(guardSource.contains("scheme == \"http\" || scheme == \"https\""),
                      "NetworkGuard no longer permits http — the ATS exception should go too")
    }

    // MARK: - Signing and distribution

    /// `security find-identity | head -1` picks an Apple Development cert on a dev Mac — signs fine,
    /// Gatekeeper rejects it elsewhere. A release must filter for Developer ID Application or refuse.
    func testReleaseSigningRequiresADeveloperIDIdentity() throws {
        let script = try read("Scripts/build_app.sh")
        XCTAssertTrue(script.contains("grep '^Developer ID Application:'"),
                      "the release path must filter for Developer ID Application identities")
        XCTAssertTrue(script.contains("GOEL_RELEASE"),
                      "there is no longer a distinct release mode")
        XCTAssertTrue(script.contains("no 'Developer ID Application' identity is installed"),
                      "a release with no distribution certificate must fail, not fall back")
    }

    /// `codesign --verify … && echo ok` does not trip `set -e` when it fails —
    /// the old form printed nothing and carried on to package the bundle.
    func testSignatureVerificationFailureAbortsTheBuild() throws {
        let script = try read("Scripts/build_app.sh")
        XCTAssertFalse(script.contains("codesign --verify --strict --deep \"$APP\" && echo"),
                       "a failing verify must abort the build, not be swallowed by set -e")
        XCTAssertTrue(script.contains("if ! codesign --verify --strict --deep \"$APP\"; then"),
                      "signature verification must be checked explicitly")
    }

    /// `codesign --verify` checks the seal, not the policy: only spctl says whether a download opens on
    /// someone else's Mac, and only `source=` distinguishes notarized from merely Developer-ID signed.
    func testGatekeeperIsAssessedBeforeAnythingIsCalledADistributable() throws {
        let script = try read("Scripts/build_app.sh")
        XCTAssertTrue(script.contains("spctl -a -vvv -t exec"),
                      "nothing runs the Gatekeeper assessment")
        XCTAssertTrue(script.contains("source=Notarized Developer ID"),
                      "a locally-accepted unnotarized bundle must not count as passing")
        XCTAssertTrue(script.contains("xcrun stapler validate"),
                      "the notarization ticket must be confirmed as stapled")
    }

    /// Every build used to emit `dist/Goel-Downloader-<version>-macos-<arch>.zip` signed or not, which
    /// is how ad-hoc builds came to be published under release names.
    func testOnlyADistributableBuildEmitsAReleaseArchive() throws {
        let script = try read("Scripts/build_app.sh")
        XCTAssertTrue(script.contains("if [ \"$DISTRIBUTABLE\" = 1 ]; then\n  VERSION="),
                      "packaging must be gated on the build actually being distributable")
        XCTAssertTrue(script.contains("no distributable archive emitted"),
                      "a dev build must say out loud that it produced nothing shippable")
    }

    /// The pre-staple notarization payload used to be written to `dist/`, where
    /// it sat next to the real artifacts waiting to be uploaded by mistake.
    func testNotarizationPayloadIsNotLeftInTheDistDirectory() throws {
        let script = try read("Scripts/build_app.sh")
        XCTAssertFalse(script.contains("\"dist/$APP_NAME.zip\""),
                       "the pre-staple zip must not be written into dist/")
        XCTAssertTrue(script.contains("$SCRATCH/$APP_NAME.zip"),
                      "the notarization payload belongs in a scratch directory")
    }

    /// The DMG is the container people download. The app inside being notarized
    /// says nothing about the image around it.
    func testDMGIsGatedSignedAndAssessed() throws {
        let script = try read("Scripts/make_dmg.sh")
        XCTAssertTrue(script.contains("xcrun stapler validate \"$APP\""),
                      "a DMG must not be built around an unnotarized app")
        XCTAssertTrue(script.contains("codesign --force --timestamp -s \"$CODESIGN_IDENTITY\" \"$DMG\""),
                      "the disk image itself must be signed")
        XCTAssertTrue(script.contains("spctl -a -t open --context context:primary-signature"),
                      "the disk image must pass the assessment a double-click performs")
    }

    // MARK: - Vendoring

    /// bundle_dylibs.sh used to warn and exit 0 on a failed `codesign --verify --deep --strict`, after
    /// which build_app.sh re-signed and packaged a bundle whose seal was already broken.
    func testVendoringFailsClosedOnABrokenSignature() throws {
        let script = try read("Scripts/bundle_dylibs.sh")
        XCTAssertFalse(script.contains("warning: codesign --verify --deep --strict reported issues"),
                       "a broken seal must fail the build, not warn")
        XCTAssertTrue(script.contains("error: bundle is not validly signed after vendoring"),
                      "the verification failure must be terminal")
    }

    /// The synthesized resource-bundle plist hardcoded 1.0.2/2 while
    /// build_app.sh derived the real pair from the git tag.
    func testSynthesizedResourceBundlePlistTracksTheAppVersion() throws {
        let script = try read("Scripts/bundle_dylibs.sh")
        XCTAssertFalse(script.contains("<string>1.0.2</string>"),
                       "the resource-bundle version must not be a literal")
        XCTAssertTrue(script.contains("<string>$short</string>"),
                      "the resource bundle must take its version from the app's Info.plist")
    }

    // MARK: - Vendored binaries

    /// yt-dlp is Developer-ID signed inside the bundle and is the one binary carrying the
    /// disable-library-validation / allow-jit entitlements. It was downloaded with no digest at all.
    func testYtDlpDownloadIsPinnedAndVerified() throws {
        let script = try read("Scripts/fetch_ytdlp.sh")
        XCTAssertTrue(script.contains("YTDLP_SHA256"),
                      "the yt-dlp asset must be pinned to a digest")
        XCTAssertTrue(script.contains("yt-dlp checksum mismatch"),
                      "a digest mismatch must be refused")
        XCTAssertTrue(script.contains("YTDLP_VERSION=latest cannot be verified"),
                      "a moving tag has no digest and must not be accepted")
    }

    /// A warning then `exit 0` meant a yt-dlp that cannot run for the target arch got signed and
    /// shipped, giving the user a "Resolve with yt-dlp" button that is present and broken.
    func testYtDlpArchAndSmokeTestFailuresAreTerminal() throws {
        let script = try read("Scripts/fetch_ytdlp.sh")
        XCTAssertFalse(script.contains("warning: bundled yt-dlp"),
                       "an unusable yt-dlp must not be downgraded to a warning")
        XCTAssertTrue(script.contains("does not include the target arch"),
                      "the arch check must compare against the TARGET, not the host")
        XCTAssertTrue(script.contains("YTDLP_ARCH"),
                      "a cross-build must be able to state the arch it is building for")
    }

    /// fetch_ffmpeg.sh ran unzip/tar over the downloaded bytes and only then compared the digest —
    /// fail-closed in the end, but an archive parser had already been pointed at unverified input.
    func testFFmpegArchiveIsVerifiedBeforeItIsUnpacked() throws {
        let script = try read("Scripts/fetch_ffmpeg.sh")
        guard let verifyIndex = script.range(of: "ACTUAL=\"$(sha256_of \"$TMP\")\""),
              let unpackIndex = script.range(of: "unzip -q -o \"$TMP\"") else {
            return XCTFail("fetch_ffmpeg.sh no longer has the download/verify/unpack sequence")
        }
        XCTAssertLessThan(verifyIndex.lowerBound, unpackIndex.lowerBound,
                          "the digest must be checked before the archive is opened")
    }

    /// The SQLite amalgamation is compiled into the .so linked by the shipped Linux daemon; it used to
    /// be located by scraping an HTML page, with no pinned version and no digest.
    func testSQLiteAmalgamationIsPinnedAndVerified() throws {
        let script = try read("Scripts/linux/build-sqlite.sh")
        XCTAssertTrue(script.contains("SQLITE_SHA256"), "the amalgamation must be pinned")
        XCTAssertTrue(script.contains("sha256sum -c -"), "the digest must be verified")
        XCTAssertFalse(script.contains("curl -s https://sqlite.org/download.html"),
                       "the unpinned, unchecked scrape must not be the default path")
    }

    // MARK: - Licences and artifacts

    /// All four are tracked files, so a missing one is a broken checkout, not a condition — and shipping
    /// the native libraries without their notices is a licence violation, not a cosmetic omission.
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

    /// The frozen `yt-dlp_macos` embeds mutagen (GPL-2.0-or-later), which the notices file used to call
    /// "permissively-licensed" while reproducing no GPL text — an obligation recorded as discharged.
    func testGPLTextAccompaniesTheBundledYtDlp() throws {
        let notices = try read("THIRD-PARTY-NOTICES.md")
        XCTAssertTrue(notices.contains("mutagen"),
                      "the GPL-2.0-or-later component inside yt-dlp must be named")
        XCTAssertFalse(notices.contains("other permissively-licensed components"),
                       "yt-dlp's embedded components are not all permissive")
        // A link to gnu.org is not a copy — the same standard the file already
        // applies to LGPL-2.1 in Appendix A.
        XCTAssertTrue(notices.contains("GNU GENERAL PUBLIC LICENSE"),
                      "the GPL-2.0 text itself must be present, not merely linked")
        XCTAssertTrue(notices.contains("Version 2, June 1991"),
                      "the reproduced licence must be version 2")
        XCTAssertTrue(notices.contains("Appendix B"),
                      "the GPL text must be reachable from the table of obligations")
    }

    /// "Mere aggregation" is what makes bundling a GPL'd executable acceptable in a PolyForm
    /// Noncommercial app — only while yt-dlp stays optional, so `BUNDLE_YTDLP=0` must stay real.
    func testMereAggregationArgumentIsRecordedAndStillTrue() throws {
        let notices = try read("THIRD-PARTY-NOTICES.md")
        XCTAssertTrue(notices.contains("mere aggregation"),
                      "the basis for bundling a GPL'd executable must be stated")
        let script = try read("Scripts/build_app.sh")
        XCTAssertTrue(script.contains("BUNDLE_YTDLP:-1"),
                      "shipping without yt-dlp must remain possible for the argument to hold")
    }

    /// The Linux tarball was assembled by hand: no build script, no licence files, and — from copying
    /// the whole toolchain lib directory — the test-only libXCTest.so and libTesting.so.
    func testLinuxDaemonHasAPackagingScriptThatShipsLicencesAndNoTestLibraries() throws {
        let script = try read("Scripts/linux/package_daemon.sh")
        XCTAssertTrue(script.contains("libXCTest\\.so|libTesting\\.so"),
                      "test-only runtime libraries must be excluded from the tarball")
        XCTAssertTrue(script.contains("THIRD-PARTY-NOTICES.md"),
                      "the tarball must carry the third-party notices")
        XCTAssertTrue(script.contains("SWIFT-RUNTIME-"),
                      "the Swift runtime's own Apache-2.0 notice must travel with its .so files")
    }

    // MARK: - CI

    /// The two worst defects this project shipped were invisible on the machine that built them, and
    /// would have been caught by one unsigned build on a clean runner.
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

    /// A commit count is monotonic only over a complete history; on a shallow clone it is 1 — below
    /// the version already shipped, which Sparkle reads as older and never offers.
    func testShallowCloneCannotStampARegressingBundleVersion() throws {
        let script = try read("Scripts/build_app.sh")
        XCTAssertTrue(script.contains("git rev-parse --is-shallow-repository"),
                      "the shallow-clone case must be detected and named")
        XCTAssertTrue(script.contains("would look OLDER"),
                      "a regressing CFBundleVersion must be refused")
    }

    /// A release with no SUFeedURL/SUPublicEDKey and no hosted appcast ships
    /// with no update path, and nothing anywhere says so.
    func testReleaseWithoutAnUpdaterMustBeAcknowledgedExplicitly() throws {
        let script = try read("Scripts/build_app.sh")
        XCTAssertTrue(script.contains("GOEL_NO_UPDATER"),
                      "shipping a release with no updater must be an explicit decision")
        XCTAssertTrue(script.contains("no update path at all"),
                      "the failure must say what is actually wrong")
    }
}

#endif
