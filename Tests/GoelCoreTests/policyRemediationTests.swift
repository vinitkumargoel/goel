import XCTest
@testable import GoelCore

/// Regression tests for the managed-policy trust boundary.
///
/// These are security tests. The rule they defend is a single sentence — *a key
/// is enforced if and only if it arrived forced* — and every case here is a way
/// that rule was previously escapable: an unforced value read off the user's own
/// preference plist and enforced as organisational policy, a bandwidth ceiling
/// dodged by handing the app an empty profile list, a policy file that any local
/// user could rewrite, and an MDM overlay baked into the user's own settings by
/// an import so that it outlived the profile that imposed it.
///
/// The remaining cases are about a policy source being *parsed input*: a number
/// that used to abort the process, and a typo that used to make a whole fleet
/// silently unmanaged.
final class ManagedPolicyRemediationTests: XCTestCase {

    private static let MiB = 1024 * 1024

    // MARK: - Forcedness is the trust boundary

    /// The core regression: a value that is present but NOT forced reached the
    /// app through a search chain ending in a plist the user can write. It is at
    /// most a seeded default, and must change nothing.
    func testUnforcedEntriesAreNeverApplied() {
        var settings = AppSettings()
        settings.proxyMode = "none"
        settings.proxyHost = ""
        settings.defaultSaveDirectory = "/Users/me/Downloads"
        settings.auditLogEnabled = false

        let policy = ManagedPolicy(entries: [
            .proxyMode: .init(value: .string("manual"), isForced: false),
            .proxyHost: .init(value: .string("10.0.0.66"), isForced: false),
            .defaultSaveDirectory: .init(value: .string("/tmp/collect"), isForced: false),
            .auditLogEnabled: .init(value: .bool(false), isForced: false),
        ])

        XCTAssertEqual(policy.apply(to: settings), settings,
                       "an unforced value is a default the user owns, never policy")
        XCTAssertTrue(policy.lockedKeys.isEmpty)
    }

    /// The other half of the same rule: a profile-delivered value still lands.
    func testForcedEntriesAreStillApplied() {
        var settings = AppSettings()
        settings.proxyMode = "none"
        settings.auditLogEnabled = false

        let policy = ManagedPolicy(entries: [
            .proxyMode: .init(value: .string("manual"), isForced: true),
            .proxyHost: .init(value: .string("proxy.corp.example.com"), isForced: true),
            .defaultSaveDirectory: .init(value: .string("/Users/Shared/Downloads"), isForced: true),
            .auditLogEnabled: .init(value: .bool(true), isForced: true),
        ])
        let effective = policy.apply(to: settings)

        XCTAssertEqual(effective.proxyMode, "manual")
        XCTAssertEqual(effective.proxyHost, "proxy.corp.example.com")
        XCTAssertEqual(effective.defaultSaveDirectory, "/Users/Shared/Downloads")
        XCTAssertTrue(effective.auditLogEnabled)
    }

    /// A single policy carrying both kinds must apply exactly the forced half —
    /// the two are decided per key, not per policy.
    func testMixedPolicyAppliesOnlyTheForcedHalf() {
        var settings = AppSettings()
        settings.proxyHost = "user-chosen.example.com"
        settings.auditLogEnabled = false

        let policy = ManagedPolicy(entries: [
            .proxyHost: .init(value: .string("10.0.0.66"), isForced: false),
            .auditLogEnabled: .init(value: .bool(true), isForced: true),
        ])
        let effective = policy.apply(to: settings)

        XCTAssertEqual(effective.proxyHost, "user-chosen.example.com")
        XCTAssertTrue(effective.auditLogEnabled)
    }

    /// A bandwidth ceiling reaches the settings by a second route — it implies
    /// `speedLimitEnabled`. That route has to be gated on forcedness too, or an
    /// unforced value still changes what the engines do.
    func testUnforcedCeilingNeitherClampsNorEnablesTheLimiter() {
        var settings = AppSettings()
        settings.speedLimitEnabled = false

        let policy = ManagedPolicy(entries: [
            .maxDownloadBytesPerSec: .init(value: .int(64 * 1024), isForced: false),
        ])
        let effective = policy.apply(to: settings)

        XCTAssertFalse(effective.speedLimitEnabled,
                       "an unforced ceiling must not switch the limiter on")
        XCTAssertEqual(effective.profiles, settings.profiles)
    }

    // MARK: - The ceiling cannot be escaped

    /// ``AppSettings/selectedProfile`` falls back to the static `.medium` when
    /// the profile list is empty, and that fallback is not in `profiles` — so
    /// clamping the list alone let an empty one (which an imported backup can
    /// supply) run at Medium's 50 MB/s under a 5 MB/s fleet ceiling.
    func testManagedCeilingSurvivesAnEmptyProfileList() {
        var settings = AppSettings()
        settings.profiles = []

        let ceiling = Int64(5 * Self.MiB)
        let policy = ManagedPolicy(forced: [.maxDownloadBytesPerSec: .int(5 * Self.MiB)])
        let effective = policy.apply(to: settings)

        XCTAssertFalse(effective.profiles.isEmpty,
                       "the fallback profile must be materialised so it can be clamped")
        XCTAssertLessThanOrEqual(effective.effectiveProfile.maxDownloadBytesPerSec, ceiling)
        for profile in effective.profiles {
            XCTAssertLessThanOrEqual(profile.maxDownloadBytesPerSec, ceiling)
        }
    }

    // MARK: - A policy file is parsed input

    /// `9e30` is valid JSON, and `Int(_:)` on a `Double` traps outside `Int`'s
    /// range — so one bad number used to abort the daemon at construction, with
    /// no diagnostic. The key must degrade to "not managed" like every other
    /// uncoercible value, leaving the rest of the file in force.
    func testOutOfRangeNumberInAPolicyFileIsIgnoredNotFatal() throws {
        let path = try Self.writePolicyFile("""
        {"maxDownloadBytesPerSec": 9e30, "auditLogEnabled": true}
        """)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let reader = try XCTUnwrap(JSONManagedPreferenceReader(contentsOfFile: path))
        let policy = ManagedPolicy.read(using: reader)

        XCTAssertFalse(policy.isManaged(.maxDownloadBytesPerSec),
                       "a number outside Int's range is not a byte count")
        XCTAssertTrue(policy.apply(to: AppSettings()).auditLogEnabled,
                      "one bad key must not cost the administrator the rest of the file")
    }

    /// A whole number that *is* in range still truncates exactly as it always
    /// did — the non-trapping conversion must not change ordinary values.
    func testFractionalNumberInAPolicyFileStillTruncates() throws {
        let path = try Self.writePolicyFile("""
        {"auditLogRetentionDays": 30.7}
        """)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let reader = try XCTUnwrap(JSONManagedPreferenceReader(contentsOfFile: path))
        let policy = ManagedPolicy.read(using: reader)

        XCTAssertEqual(policy.apply(to: AppSettings()).auditLogRetentionDays, 30)
    }

    /// A file that exists but does not parse is an administrator's typo. The app
    /// still runs unmanaged — refusing to launch over a stray comma would be
    /// worse — but the two outcomes must not be the same code path.
    func testMalformedPolicyFileMeansUnmanaged() throws {
        let path = try Self.writePolicyFile("not json")
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertNil(JSONManagedPreferenceReader(contentsOfFile: path))
    }

    /// The file's authority is its permissions and nothing else. One a local
    /// user can rewrite is how they would grant themselves a fleet proxy and
    /// turn the audit log off, so it is refused rather than trusted.
    func testGroupOrWorldWritablePolicyFileIsRefused() throws {
        let path = try Self.writePolicyFile("""
        {"proxyMode": "manual", "proxyHost": "10.0.0.66"}
        """)
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertNotNil(JSONManagedPreferenceReader(contentsOfFile: path),
                        "0644 is the mode an administrator installs, and must be accepted")

        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: path)
        XCTAssertNil(JSONManagedPreferenceReader(contentsOfFile: path))

        try FileManager.default.setAttributes([.posixPermissions: 0o664], ofItemAtPath: path)
        XCTAssertNil(JSONManagedPreferenceReader(contentsOfFile: path))
    }

    // MARK: - The managed-preferences directory

    #if os(macOS)
    /// Everything under `/Library/Managed Preferences` is forced by
    /// construction: writing there already required root. The per-user profile
    /// overlays the device one, which is the precedence CoreFoundation applies.
    func testManagedPreferenceDirectoryIsForcedAndUserScopeWins() throws {
        let root = NSTemporaryDirectory() + "goel-managed-\(UUID().uuidString)"
        let user = "tester"
        try FileManager.default.createDirectory(atPath: root + "/" + user,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        try Self.writePlist(["proxyHost": "device.example.com", "auditLogEnabled": true],
                            to: root + "/com.goel.downloader.plist")
        try Self.writePlist(["proxyHost": "user.example.com"],
                            to: root + "/" + user + "/com.goel.downloader.plist")

        let reader = try XCTUnwrap(ManagedPreferencePathReader(
            domain: "com.goel.downloader", user: user, root: root))
        let policy = ManagedPolicy.read(using: reader)
        let effective = policy.apply(to: AppSettings())

        XCTAssertTrue(policy.isLocked(.proxyHost), "a profile on disk is forced by construction")
        XCTAssertEqual(effective.proxyHost, "user.example.com", "user scope wins over device scope")
        XCTAssertTrue(effective.auditLogEnabled, "device-scope keys survive the overlay")
    }

    /// No profile at that path means "fall back", not "unmanaged" — so the
    /// reader must decline rather than report an empty policy.
    func testManagedPreferenceDirectoryWithNoProfileDeclines() throws {
        let root = NSTemporaryDirectory() + "goel-managed-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        XCTAssertNil(ManagedPreferencePathReader(
            domain: "com.goel.downloader", user: "tester", root: root))
    }
    #endif

    // MARK: - Import must not bake the overlay in

    /// Importing a backup restores the security-sensitive fields from the
    /// CURRENT values — and "current" has to mean the user's own row, not the
    /// policy-overlaid one. Passing the effective row wrote the administrator's
    /// forced keys to disk as if the user had chosen them, so they survived
    /// removal of the profile that imposed them.
    func testImportKeepsThePolicyOverlayOutOfTheUsersOwnSettings() async throws {
        var mine = AppSettings()
        mine.proxyMode = "none"
        mine.proxyHost = "my-own-proxy.example.com"

        let manager = DownloadManager(
            httpEngine: MockTorrentEngine(), torrentEngine: MockTorrentEngine(),
            settings: mine, store: try PersistenceStore())
        await manager.installPolicyForTest(ManagedPolicy(forced: [
            .proxyMode: .string("manual"),
            .proxyHost: .string("mdm-proxy.corp.example.com"),
        ]))

        let source = try XCTUnwrap(DownloadSource.parse("https://example.com/file.bin"))
        let donor = DownloadManager(
            httpEngine: MockTorrentEngine(), torrentEngine: MockTorrentEngine(),
            settings: AppSettings(), store: try PersistenceStore())
        _ = await donor.add(source: source)
        let envelope = try await donor.exportEnvelope()

        _ = try await manager.importEnvelope(envelope)

        let effective = await manager.currentSettings
        XCTAssertEqual(effective.proxyHost, "mdm-proxy.corp.example.com",
                       "the overlay is still live after an import")
        let stored = await manager.storedSettingsForTest
        XCTAssertEqual(stored.proxyHost, "my-own-proxy.example.com",
                       "the administrator's proxy must not be persisted as the user's choice")
        XCTAssertEqual(stored.proxyMode, "none")
    }

    // MARK: - Helpers

    /// Write `json` to a fresh temporary file at the mode an administrator would
    /// install it with. The mode is set explicitly because the reader now
    /// refuses a file others can write, and a test must not depend on the
    /// process umask to decide which side of that line it lands on.
    private static func writePolicyFile(_ json: String) throws -> String {
        let path = NSTemporaryDirectory() + "goel-policy-\(UUID().uuidString).json"
        try Data(json.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        return path
    }

    #if os(macOS)
    private static func writePlist(_ object: [String: Any], to path: String) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: object,
                                                      format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
    }
    #endif
}

private extension DownloadManager {
    /// Install an overlay directly. Production always goes through
    /// ``refreshManagedPolicy()``; there is no way to enrol a Mac from a unit
    /// test, and the import path has to be exercised with a policy in force.
    func installPolicyForTest(_ policy: ManagedPolicy) async {
        managedPolicy = policy
        await updateSettings(storedSettings)
    }

    /// The user's own row — the only thing ever persisted.
    var storedSettingsForTest: AppSettings { storedSettings }
}
