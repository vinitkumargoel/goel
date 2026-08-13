import XCTest
@testable import GoelCore

/// A managed policy file's only authority is its permissions: anyone who can rewrite it can point the
/// fleet at their own proxy and switch the audit log off. `isWritableByOthers` therefore fails closed —
/// a present file whose mode will not read counts as writable, never as trusted — while a file that is
/// simply absent stays "absent", so unmanaged machines don't log a refusal on every launch.
///
/// `isWritableByOthers` is file-private, so these tests drive it through the two readers that gate on
/// it: a refused file contributes nothing, an owner-only one contributes its values.
///
/// Both of those readers collapse "refused" and "absent" to the same nil, so the two branches the
/// fail-closed change actually flipped — a present file whose mode will not stat, and a file that is
/// not there — produce identical results at every surface outside this module. What is pinned here is
/// the trust rule those branches serve: a file anyone else can rewrite is never policy, and an
/// owner-only one always is.
final class ManagedPolicyTrustTests: XCTestCase {

    private var tempDirs: [URL] = []

    override func tearDownWithError() throws {
        for dir in tempDirs {
            // Restore a mode we can definitely delete through before removing.
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
    }

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("goel-managed-policy-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    /// Writes `contents` and forces `mode`, so the test never depends on the process umask.
    private func write(_ contents: Data, to url: URL, mode: Int) throws {
        try contents.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    private func policyJSON(saveDirectory: String) -> Data {
        Data("{\"defaultSaveDirectory\": \"\(saveDirectory)\"}".utf8)
    }

    // MARK: - JSON policy file (the Linux / `--managed-policy` reader)

    func testWorldWritablePolicyFileIsRefusedEvenThoughItsJSONIsValid() throws {
        let dir = makeTempDir()
        let path = dir.appendingPathComponent("managed-policy.json")
        try write(policyJSON(saveDirectory: "/tmp/attacker"), to: path, mode: 0o666)

        XCTAssertNil(JSONManagedPreferenceReader(contentsOfFile: path.path),
                     "a world-writable policy file was trusted: any local user can grant themselves a fleet proxy and disable the audit log by editing it")
    }

    func testGroupWritablePolicyFileIsRefused() throws {
        let dir = makeTempDir()
        let path = dir.appendingPathComponent("managed-policy.json")
        // 0664 is the mode a well-meaning admin lands on with a shared `staff` group — still every
        // member of that group, not just root, deciding what the fleet's policy says.
        try write(policyJSON(saveDirectory: "/tmp/attacker"), to: path, mode: 0o664)

        XCTAssertNil(JSONManagedPreferenceReader(contentsOfFile: path.path),
                     "a group-writable policy file was trusted: every member of the file's group can rewrite fleet policy")
    }

    func testOwnerOnlyWritablePolicyFileIsAcceptedAndApplied() throws {
        let dir = makeTempDir()
        let path = dir.appendingPathComponent("managed-policy.json")
        try write(policyJSON(saveDirectory: "/srv/downloads"), to: path, mode: 0o644)

        // Guards the fix against over-correcting: failing closed must not reject the normal 0644 case,
        // or every managed machine silently drops its policy.
        let reader = try XCTUnwrap(JSONManagedPreferenceReader(contentsOfFile: path.path),
                                   "a 0644 policy file was refused — managed machines would silently lose their policy")
        let policy = ManagedPolicy.read(using: reader)
        XCTAssertTrue(policy.isLocked(.defaultSaveDirectory),
                      "everything in this reader is policy by construction, so it must read as forced")
        XCTAssertEqual(policy.value(for: .defaultSaveDirectory), .string("/srv/downloads"))
    }

    func testMissingPolicyFileIsAbsentNotUntrusted() throws {
        let dir = makeTempDir()
        let path = dir.appendingPathComponent("managed-policy.json")

        XCTAssertNil(JSONManagedPreferenceReader(contentsOfFile: path.path),
                     "an unmanaged machine has no policy file and must simply read as unmanaged")

        // The visible difference between "absent" and "untrusted" is only the refusal log, which has no
        // test sink — but the states must not be conflated: reading the absent path leaves nothing
        // sticky behind, so dropping a properly-owned file at the same path is still honoured.
        try write(policyJSON(saveDirectory: "/srv/downloads"), to: path, mode: 0o644)
        XCTAssertNotNil(JSONManagedPreferenceReader(contentsOfFile: path.path),
                        "a path that read as absent a moment ago must still accept a well-owned policy file")
    }

    // MARK: - `/Library/Managed Preferences` plists

    #if os(macOS)

    private func writePlist(_ object: [String: Any], to url: URL, mode: Int) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
        try write(data, to: url, mode: mode)
    }

    func testWorldWritableManagedPlistIsDroppedWhileTheOwnerOnlyOneStillApplies() throws {
        let root = makeTempDir()
        let user = "policyuser"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(user),
                                                withIntermediateDirectories: true)
        // Device-level plist: correctly owned, so its value is policy.
        try writePlist(["defaultSaveDirectory": "/srv/downloads"],
                       to: root.appendingPathComponent("\(ManagedPolicy.domain).plist"), mode: 0o644)
        // User-level plist normally *overrides* the device-level one — which is exactly why a
        // world-writable copy must be dropped rather than merged over the trusted value.
        try writePlist(["defaultSaveDirectory": "/tmp/attacker"],
                       to: root.appendingPathComponent("\(user)/\(ManagedPolicy.domain).plist"), mode: 0o666)

        let reader = try XCTUnwrap(ManagedPreferencePathReader(domain: ManagedPolicy.domain,
                                                              user: user, root: root.path))
        XCTAssertEqual(ManagedPolicy.read(using: reader).value(for: .defaultSaveDirectory),
                       .string("/srv/downloads"),
                       "a world-writable managed plist overrode the trusted one: a local user can redirect every download by writing that file")
    }

    func testOwnerOnlyUserManagedPlistStillOverridesTheDeviceOne() throws {
        let root = makeTempDir()
        let user = "policyuser"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(user),
                                                withIntermediateDirectories: true)
        try writePlist(["defaultSaveDirectory": "/srv/downloads"],
                       to: root.appendingPathComponent("\(ManagedPolicy.domain).plist"), mode: 0o644)
        try writePlist(["defaultSaveDirectory": "/srv/per-user"],
                       to: root.appendingPathComponent("\(user)/\(ManagedPolicy.domain).plist"), mode: 0o644)

        // Guards the fix against over-correcting: the per-user override is a real MDM feature and a
        // 0644 plist must still win over the device-level one.
        let reader = try XCTUnwrap(ManagedPreferencePathReader(domain: ManagedPolicy.domain,
                                                              user: user, root: root.path))
        XCTAssertEqual(ManagedPolicy.read(using: reader).value(for: .defaultSaveDirectory),
                       .string("/srv/per-user"),
                       "refusing writable plists must not also refuse well-owned per-user overrides")
    }

    func testAMissingDeviceLevelPlistDoesNotBlockTheUserLevelOne() throws {
        let root = makeTempDir()
        let user = "policyuser"
        try FileManager.default.createDirectory(at: root.appendingPathComponent(user),
                                                withIntermediateDirectories: true)
        // No device-level plist at all — the common case on a machine with only a user-scoped profile.
        try writePlist(["defaultSaveDirectory": "/srv/per-user"],
                       to: root.appendingPathComponent("\(user)/\(ManagedPolicy.domain).plist"), mode: 0o644)

        let reader = try XCTUnwrap(ManagedPreferencePathReader(domain: ManagedPolicy.domain,
                                                              user: user, root: root.path),
                                   "an absent device-level plist was treated as a trust failure instead of as absent")
        XCTAssertEqual(ManagedPolicy.read(using: reader).value(for: .defaultSaveDirectory),
                       .string("/srv/per-user"))
    }

    #endif

    // MARK: - The trust predicate itself
    //
    // Both readers collapse "refused" and "absent" into the same nil, so the two branches the
    // fail-closed change flipped are invisible through them. These reach the predicate directly.

    // The "present but unreadable permissions" branch is deliberately untested: `fileExists` and
    // `attributesOfItem` both stat the same path, so on a local filesystem they always agree and
    // the branch is unreachable. It guards a stale network mount or a delete racing the read.

    func testAnAbsentFileIsAbsentRatherThanUntrusted() {
        // Every unmanaged machine has no policy file. Calling that untrusted would log a
        // group/world-writable error on each launch and cry wolf about a file nobody installed.
        let missing = makeTempDir().appendingPathComponent("managed-policy.json").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing))
        XCTAssertFalse(isWritableByOthers(missing),
                       "an absent policy file must not be reported as group/world-writable")
    }

    func testTheTrustPredicateReadsTheActualPermissionBits() throws {
        let root = makeTempDir()
        for (mode, untrusted) in [(0o644, false), (0o664, true), (0o666, true),
                                  (0o600, false), (0o622, true)] {
            let file = root.appendingPathComponent("policy-\(String(mode, radix: 8)).json")
            try Data("{}".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: mode],
                                                  ofItemAtPath: file.path)
            XCTAssertEqual(isWritableByOthers(file.path), untrusted,
                           "mode 0\(String(mode, radix: 8)) was judged wrongly")
        }
    }
}
