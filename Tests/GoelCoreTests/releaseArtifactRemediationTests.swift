import XCTest

/// Regression tests for the two ways a *release artifact* could be produced
/// without having passed the gates that exist to vet it.
///
/// Both defects lived in `Scripts/make_dmg.sh`, and both came from the same
/// mistaken assumption — that the DMG is a presentation step at the end of
/// `build_app.sh` rather than a release path in its own right. It is invoked
/// separately (RELEASE.md's own sequence does exactly that), it can be handed any
/// bundle at all, and the file it writes is the one the website tells people to
/// download.
///
///   * B1 — it ran none of `build_app.sh`'s gates over the payload, so a bundle
///     whose deployment-target gate had been *waived* by `GOEL_LOCAL_DEV=1` (but
///     which was still notarized and stapled) was wrapped into a signed,
///     notarized, Gatekeeper-clean `.dmg` full of dylibs that cannot launch on the
///     macOS the bundle advertises.
///   * B2 — it created the image in `dist/` under the release filename and only
///     then signed, notarized and assessed it, so every failure after that point
///     exited 1 and left the file behind for `gh release create dist/*.dmg` to
///     publish.
///
/// The script is run for real, in a throwaway copy of the repo layout, with the
/// Apple tools it drives replaced by stubs on `PATH` — the point is to observe
/// what ends up in `dist/`, which no amount of reading the source can establish.
/// `vtool`, `lipo`, `file` and `PlistBuddy` stay real, because the gate's actual
/// job is to read Mach-O load commands.
final class ReleaseArtifactRemediationTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // GoelCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
    }

    private func read(_ relativePath: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    // MARK: - B1: the deployment-target gate reaches the DMG

    /// `GOEL_LOCAL_DEV=1` may waive the gate, but it must not be able to *hide*
    /// that it did: exit 3 is what lets a caller tell "passed" from "waived", and
    /// it is the whole mechanism by which the waiver stays throwaway.
    func testWaivedDeploymentTargetGateExitsThreeRatherThanZero() throws {
        let fixture = try makeFixtureBundle(minimumSystemVersion: "10.0")
        defer { try? FileManager.default.removeItem(at: fixture) }

        let (status, output) = try run(script: "Scripts/check_min_os.sh", in: repoRoot,
                                       arguments: [fixture.path],
                                       environment: ["GOEL_LOCAL_DEV": "1"])
        XCTAssertEqual(status, 3, "a waived gate must be distinguishable from a pass:\n\(output)")
        XCTAssertTrue(output.contains("NOT shippable"), output)
    }

    /// The defect in the field was a *vendored dylib* out-targeting the bundle, and
    /// those land in `Contents/Frameworks` — not in `Contents/MacOS`, where the
    /// existing fixture puts its Mach-O. The gate walks the whole of `Contents` now
    /// rather than an allow-list of four directories, so a `Contents/Library` or
    /// `Contents/XPCServices` added later cannot be excused by omission either.
    func testGateCatchesAnOffenderAnywhereInsideTheBundle() throws {
        let fm = FileManager.default
        for location in ["Contents/Frameworks/libfixture.dylib",
                         "Contents/XPCServices/Helper",
                         "Contents/Library/Support/Tool"] {
            let fixture = try makeFixtureBundle(minimumSystemVersion: "10.0")
            defer { try? fm.removeItem(at: fixture) }
            // Move the only Mach-O out of Contents/MacOS so the offender is found
            // *there* and nowhere else. The plist still names it as the executable,
            // which is fine — this gate reads load commands, not launch paths.
            let planted = fixture.appendingPathComponent(location)
            try fm.createDirectory(at: planted.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)
            try fm.moveItem(at: fixture.appendingPathComponent("Contents/MacOS/Fixture"),
                            to: planted)

            let (status, output) = try run(script: "Scripts/check_min_os.sh", in: repoRoot,
                                           arguments: [fixture.path], environment: [:])
            XCTAssertNotEqual(status, 0, "an offender in \(location) was not caught:\n\(output)")
            XCTAssertTrue(output.contains(location), output)
        }
    }

    /// A pass is still a pass — a gate that reports "waived" for a correct bundle
    /// would make the status useless.
    func testUnwaivedPassStillExitsZeroUnderLocalDev() throws {
        let fixture = try makeFixtureBundle(minimumSystemVersion: "14.0")
        defer { try? FileManager.default.removeItem(at: fixture) }

        let (status, output) = try run(script: "Scripts/check_min_os.sh", in: repoRoot,
                                       arguments: [fixture.path],
                                       environment: ["GOEL_LOCAL_DEV": "1"])
        XCTAssertEqual(status, 0, "a correctly-targeted bundle must exit 0:\n\(output)")
    }

    /// A stapled ticket is a distribution credential, and `make_dmg.sh` trusts it.
    /// `DISTRIBUTABLE=0` did not protect anything here: it only guards the `.zip`,
    /// while the notarize+staple block is gated on `CODESIGN_IDENTITY` alone. So a
    /// waived bundle must not be notarized at all.
    func testBuildAppRefusesToNotarizeABundleWhoseGateWasWaived() throws {
        let script = try read("Scripts/build_app.sh")
        XCTAssertTrue(script.contains("refusing to notarize"),
                      "a waived bundle must not be handed a notarization ticket")
        XCTAssertTrue(script.contains("MINOS_OK"),
                      "build_app.sh must record whether the gate passed honestly")
        // Both call sites must go through the wrapper that reads the exit status;
        // invoking the gate bare discards the 3 and reads a waiver as a pass.
        XCTAssertEqual(script.components(separatedBy: "minos_gate \"$APP\"").count - 1, 2,
                       "both deployment-target gate calls must read the exit status")
    }

    /// The gate has to run in `make_dmg.sh` itself. Nothing guarantees
    /// `build_app.sh` ran in the same invocation — and `Scripts/make_dmg.sh
    /// <path>` will wrap any bundle it is pointed at, including one built before
    /// the gate existed.
    func testDMGRefusesAPayloadThatFailsTheDeploymentTargetGate() throws {
        let sandbox = try makeSandbox(minimumSystemVersion: "10.0")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let (status, output) = try runMakeDMG(sandbox)
        XCTAssertNotEqual(status, 0, "an over-targeted payload was wrapped anyway:\n\(output)")
        XCTAssertTrue(output.contains("check_min_os.sh"), output)
        XCTAssertEqual(try dmgsInDist(sandbox), [],
                       "a refused build must leave nothing in dist/")
    }

    /// `stapler validate` proves a ticket is attached; it cannot say whether the
    /// certificate behind it is still good. Only Gatekeeper's `source=` line
    /// separates "notarized" from "signed with a Developer ID and accepted on the
    /// machine that signed it".
    func testDMGRequiresANotarizedGatekeeperVerdictForItsPayload() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let (status, output) = try runMakeDMG(sandbox, environment: [
            "GOEL_TEST_APP_SOURCE": "Developer ID",
        ])
        XCTAssertNotEqual(status, 0, "an unnotarized payload was accepted:\n\(output)")
        XCTAssertTrue(output.contains("but not as notarized"), output)
        XCTAssertEqual(try dmgsInDist(sandbox), [], "nothing may be left in dist/")
    }

    // MARK: - B2: dist/ is written only by a build that passed

    /// Apple returning `Invalid` is an ordinary outcome — a revoked certificate, a
    /// rejected entitlement, an outage. The script exits 1 either way; what must
    /// not happen is a release-named image surviving in `dist/`, because the next
    /// documented step publishes `dist/*.dmg` with no further check.
    func testFailedNotarizationLeavesNothingInDist() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let (status, output) = try runMakeDMG(sandbox, environment: [
            "GOEL_TEST_NOTARY_STATUS": "Invalid",
        ])
        XCTAssertNotEqual(status, 0, "a rejected notarization must fail the build:\n\(output)")
        XCTAssertEqual(try dmgsInDist(sandbox), [],
                       "a rejected notarization left a release-named image in dist/")
    }

    /// The last gate is the assessment a double-click performs. A rejection there
    /// is the clearest possible statement that the image will not open on anyone
    /// else's Mac, so it must not be the file left sitting under the release name.
    func testGatekeeperRejectionOfTheImageLeavesNothingInDist() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let (status, output) = try runMakeDMG(sandbox, environment: [
            "GOEL_TEST_DMG_SPCTL_EXIT": "1",
        ])
        XCTAssertNotEqual(status, 0, "a rejected image must fail the build:\n\(output)")
        XCTAssertTrue(output.contains("Gatekeeper rejected"), output)
        XCTAssertEqual(try dmgsInDist(sandbox), [],
                       "a Gatekeeper-rejected image left a release-named file in dist/")
    }

    /// And the happy path still produces the artifact — a script that never writes
    /// `dist/` is not a fix.
    func testEverythingPassingWritesExactlyOneImageIntoDist() throws {
        let sandbox = try makeSandbox()
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let (status, output) = try runMakeDMG(sandbox)
        XCTAssertEqual(status, 0, "the happy path failed:\n\(output)")
        let images = try dmgsInDist(sandbox)
        XCTAssertEqual(images.count, 1, "expected one image, got \(images)")
        XCTAssertTrue(images.first?.hasPrefix("Goel-Downloader-9.9.9-macos-") == true, images.description)
    }

    /// A local/dev image must not be written under a release name in the directory
    /// the release upload reads from, waiver or no waiver.
    func testLocalDevImageIsNeverWrittenIntoDist() throws {
        let sandbox = try makeSandbox(minimumSystemVersion: "10.0")
        defer { try? FileManager.default.removeItem(at: sandbox.root) }

        let (status, output) = try runMakeDMG(sandbox, environment: ["GOEL_LOCAL_DEV": "1"])
        XCTAssertEqual(status, 0, "a local image should still build:\n\(output)")
        XCTAssertEqual(try dmgsInDist(sandbox), [],
                       "a local/dev image must stay out of dist/")
        XCTAssertTrue(output.contains("NOT for distribution"), output)
    }

    /// `dist/` is not pruned between releases, so a glob uploads whatever is still
    /// lying there — including artifacts from a version nobody is releasing, built
    /// before any of these gates existed.
    func testReleaseInstructionsNameTheArtifactsRatherThanGlobbingDist() throws {
        let release = try read("RELEASE.md")
        XCTAssertFalse(release.contains("dist/*.dmg dist/*.zip"),
                       "the publish step must not glob dist/")
    }

    // MARK: - Harness

    /// A throwaway directory laid out like the repo — `Scripts/` holding the two
    /// scripts under test, and a `dist/` with a fixture bundle. `make_dmg.sh`
    /// resolves the repo root from its own path, so a copy is enough to keep the
    /// real `dist/` untouched.
    private struct Sandbox {
        let root: URL
        let app: URL
        let stubs: URL
    }

    private func makeSandbox(minimumSystemVersion: String = "14.0") throws -> Sandbox {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("GoelDMGSandbox-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("Scripts"),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("dist"),
                               withIntermediateDirectories: true)
        for script in ["make_dmg.sh", "check_min_os.sh"] {
            try fm.copyItem(at: repoRoot.appendingPathComponent("Scripts/\(script)"),
                            to: root.appendingPathComponent("Scripts/\(script)"))
        }
        let app = try makeFixtureBundle(minimumSystemVersion: minimumSystemVersion,
                                        in: root.appendingPathComponent("dist"))
        return Sandbox(root: root, app: app, stubs: try makeStubs(in: root))
    }

    /// A `.app` carrying a real Mach-O and the Info.plist keys both scripts read.
    /// `/bin/ls` targets macOS 11, so it passes a 14.0 claim and fails a 10.0 one —
    /// the exact shape of the defect (a binary needing a newer OS than the bundle
    /// advertises).
    private func makeFixtureBundle(minimumSystemVersion: String,
                                   in directory: URL? = nil) throws -> URL {
        let fm = FileManager.default
        let parent = directory ?? fm.temporaryDirectory
        let bundle = parent.appendingPathComponent("GoelDMGFixture-\(UUID().uuidString).app")
        let macOS = bundle.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: "/bin/ls"),
                        to: macOS.appendingPathComponent("Fixture"))
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleExecutable</key>
            <string>Fixture</string>
            <key>CFBundleShortVersionString</key>
            <string>9.9.9</string>
            <key>LSMinimumSystemVersion</key>
            <string>\(minimumSystemVersion)</string>
            <key>NSAppleEventsUsageDescription</key>
            <string>Fixture asks System Events to shut down.</string>
            <key>NSLocalNetworkUsageDescription</key>
            <string>Fixture serves a portal on your network.</string>
        </dict>
        </plist>

        """
        try plist.write(to: bundle.appendingPathComponent("Contents/Info.plist"),
                        atomically: true, encoding: .utf8)
        return bundle
    }

    /// Stand-ins for the Apple tools the script drives, so the *decisions* can be
    /// exercised without a certificate, a notary account or a real disk image. Each
    /// stub's outcome is steered by an environment variable so one test can make
    /// notarization fail and another the final assessment.
    private func makeStubs(in root: URL) throws -> URL {
        let stubs = root.appendingPathComponent("stubs")
        try FileManager.default.createDirectory(at: stubs, withIntermediateDirectories: true)
        try write("""
        #!/bin/bash
        # xcrun stapler validate|staple … ; xcrun notarytool submit … --wait
        if [ "$1" = "notarytool" ]; then
          status="${GOEL_TEST_NOTARY_STATUS:-Accepted}"
          echo "    status: $status"
          [ "$status" = "Accepted" ] || exit 1
        fi
        exit 0
        """, to: stubs.appendingPathComponent("xcrun"))
        try write("""
        #!/bin/bash
        # `-t exec` assesses the app, `-t open` the disk image.
        mode=""
        for a in "$@"; do
          case "$a" in exec) mode=exec ;; open) mode=open ;; esac
        done
        if [ "$mode" = "exec" ]; then
          echo "accepted"
          echo "source=${GOEL_TEST_APP_SOURCE:-Notarized Developer ID}"
          exit "${GOEL_TEST_APP_SPCTL_EXIT:-0}"
        fi
        echo "assessing image"
        exit "${GOEL_TEST_DMG_SPCTL_EXIT:-0}"
        """, to: stubs.appendingPathComponent("spctl"))
        try write("""
        #!/bin/bash
        exit 0
        """, to: stubs.appendingPathComponent("codesign"))
        try write("""
        #!/bin/bash
        # hdiutil create … <output>; the image is the last argument.
        out=""
        for a in "$@"; do out="$a"; done
        printf 'not a real disk image\\n' > "$out"
        exit 0
        """, to: stubs.appendingPathComponent("hdiutil"))
        return stubs
    }

    private func write(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func runMakeDMG(_ sandbox: Sandbox,
                            environment: [String: String] = [:]) throws -> (Int32, String) {
        var env = environment
        env["PATH"] = sandbox.stubs.path + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
        if env["GOEL_LOCAL_DEV"] != "1" {
            env["CODESIGN_IDENTITY"] = env["CODESIGN_IDENTITY"] ?? "Developer ID Application: Fixture (TEAMID)"
            env["NOTARY_PROFILE"] = env["NOTARY_PROFILE"] ?? "fixture-profile"
        }
        return try run(script: "Scripts/make_dmg.sh", in: sandbox.root,
                       arguments: [sandbox.app.path], environment: env)
    }

    /// The `.dmg` files sitting in a sandbox's `dist/` — the only thing that
    /// actually decides whether a failed run is publishable.
    private func dmgsInDist(_ sandbox: Sandbox) throws -> [String] {
        let dist = sandbox.root.appendingPathComponent("dist")
        let contents = try FileManager.default.contentsOfDirectory(atPath: dist.path)
        return contents.filter { $0.hasSuffix(".dmg") }.sorted()
    }

    /// Run a script from `root` and return (exit status, combined output).
    private func run(script relativePath: String, in root: URL, arguments: [String],
                     environment: [String: String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [root.appendingPathComponent(relativePath).path] + arguments
        process.currentDirectoryURL = root
        var env = ProcessInfo.processInfo.environment
        environment.forEach { env[$0.key] = $0.value }
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
