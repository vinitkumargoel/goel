import XCTest
@testable import GoelCore

/// Managed-policy trust boundary: a key is enforced if and only if it arrived forced.
final class ManagedPolicyRemediationTests: XCTestCase {

    private static let MiB = 1024 * 1024

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

    /// A ceiling also implies `speedLimitEnabled`; that second route must be gated on forcedness too.
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

    /// `selectedProfile` falls back to the static `.medium`, which is not in `profiles` — clamping the list alone left an empty one uncapped.
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

    /// `9e30` is valid JSON and `Int(_:)` traps outside `Int`'s range; the key must degrade to "not managed", not abort the daemon.
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

    func testFractionalNumberInAPolicyFileStillTruncates() throws {
        let path = try Self.writePolicyFile("""
        {"auditLogRetentionDays": 30.7}
        """)
        defer { try? FileManager.default.removeItem(atPath: path) }

        let reader = try XCTUnwrap(JSONManagedPreferenceReader(contentsOfFile: path))
        let policy = ManagedPolicy.read(using: reader)

        XCTAssertEqual(policy.apply(to: AppSettings()).auditLogRetentionDays, 30)
    }

    func testMalformedPolicyFileMeansUnmanaged() throws {
        let path = try Self.writePolicyFile("not json")
        defer { try? FileManager.default.removeItem(atPath: path) }

        XCTAssertNil(JSONManagedPreferenceReader(contentsOfFile: path))
    }

    /// The file's authority is its permissions: one a local user can rewrite would grant them a fleet proxy and disable the audit log.
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

    #if os(macOS)
    /// Everything under `/Library/Managed Preferences` is forced by construction (writing there needs root); user scope overlays device.
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

    func testManagedPreferenceDirectoryWithNoProfileDeclines() throws {
        let root = NSTemporaryDirectory() + "goel-managed-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        XCTAssertNil(ManagedPreferencePathReader(
            domain: "com.goel.downloader", user: "tester", root: root))
    }
    #endif

    /// Import restores security-sensitive fields from CURRENT values, which must be the user's own row, not the policy overlay.
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

    /// Mode set explicitly: the reader refuses group/world-writable files, so umask must not decide it.
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
    func installPolicyForTest(_ policy: ManagedPolicy) async {
        managedPolicy = policy
        await updateSettings(storedSettings)
    }

    var storedSettingsForTest: AppSettings { storedSettings }
}
