import XCTest
@testable import GoelCore

final class EnterpriseTests: XCTestCase {

    func testEmptyPolicyChangesNothing() {
        let settings = AppSettings()
        let policy = ManagedPolicy()
        XCTAssertTrue(policy.isEmpty)
        XCTAssertEqual(policy.apply(to: settings), settings)
    }

    func testManagedValuesOverrideUserSettings() {
        var settings = AppSettings()
        settings.defaultSaveDirectory = "/Users/me/Downloads"
        settings.proxyMode = "none"
        settings.updateFeedURL = ""

        let policy = ManagedPolicy(forced: [
            .defaultSaveDirectory: .string("/Users/Shared/Downloads"),
            .proxyMode: .string("manual"),
            .proxyHost: .string("proxy.example.com"),
            .proxyPort: .int(3128),
            .updateFeedURL: .string("https://software.example.com/appcast.xml"),
        ])
        let effective = policy.apply(to: settings)

        XCTAssertEqual(effective.defaultSaveDirectory, "/Users/Shared/Downloads")
        XCTAssertEqual(effective.proxyMode, "manual")
        XCTAssertEqual(effective.proxyHost, "proxy.example.com")
        XCTAssertEqual(effective.proxyPort, 3128)
        XCTAssertEqual(effective.updateFeedURL, "https://software.example.com/appcast.xml")
    }

    func testUnmanagedKeysAreLeftAlone() {
        var settings = AppSettings()
        settings.theme = "aurora-light"
        settings.retryCount = 9
        settings.userAgent = "Custom/2.0"

        let effective = ManagedPolicy(forced: [.proxyMode: .string("system")]).apply(to: settings)

        XCTAssertEqual(effective.theme, "aurora-light")
        XCTAssertEqual(effective.retryCount, 9)
        XCTAssertEqual(effective.userAgent, "Custom/2.0")
        XCTAssertEqual(effective.proxyMode, "system")
    }

    func testBandwidthCeilingClampsEveryProfile() {
        let settings = AppSettings()
        let ceiling: Int64 = 5 * 1024 * 1024
        let effective = ManagedPolicy(forced: [
            .maxDownloadBytesPerSec: .int(Int(ceiling)),
        ]).apply(to: settings)

        XCTAssertFalse(effective.profiles.isEmpty)
        for profile in effective.profiles {
            XCTAssertLessThanOrEqual(profile.maxDownloadBytesPerSec, ceiling,
                                     "\(profile.name) escaped the managed ceiling")
        }
        let low = effective.profiles.first { $0.name == "Low" }
        XCTAssertEqual(low?.maxDownloadBytesPerSec, TrafficProfile.low.maxDownloadBytesPerSec)
    }

    func testCeilingImpliesSpeedLimitEnabled() {
        var settings = AppSettings()
        settings.speedLimitEnabled = false
        let effective = ManagedPolicy(forced: [
            .maxUploadBytesPerSec: .int(256 * 1024),
        ]).apply(to: settings)
        XCTAssertTrue(effective.speedLimitEnabled)
        XCTAssertEqual(effective.effectiveProfile.maxUploadBytesPerSec, 256 * 1024)
    }

    func testExplicitSpeedLimitFlagBeatsTheImplication() {
        let effective = ManagedPolicy(forced: [
            .maxDownloadBytesPerSec: .int(1024),
            .speedLimitEnabled: .bool(false),
        ]).apply(to: AppSettings())
        XCTAssertFalse(effective.speedLimitEnabled)
    }

    func testUncoercibleValuesAreIgnored() {
        var settings = AppSettings()
        settings.proxyPort = 8080
        settings.remoteReadOnly = false
        let effective = ManagedPolicy(forced: [
            .proxyPort: .string("eight-thousand"),
            .remoteReadOnly: .string("maybe"),
        ]).apply(to: settings)
        XCTAssertEqual(effective.proxyPort, 8080)
        XCTAssertFalse(effective.remoteReadOnly)
    }

    func testLenientBooleanAndNumberCoercion() {
        let effective = ManagedPolicy(forced: [
            .auditLogEnabled: .string("yes"),
            .remoteReadOnly: .int(1),
            .auditLogRetentionDays: .string("365"),
        ]).apply(to: AppSettings())
        XCTAssertTrue(effective.auditLogEnabled)
        XCTAssertTrue(effective.remoteReadOnly)
        XCTAssertEqual(effective.auditLogRetentionDays, 365)
    }

    func testManagedAndLockedKeysAreReportedSeparately() {
        let policy = ManagedPolicy(entries: [
            .defaultSaveDirectory: .init(value: .string("/Users/Shared"), isForced: true),
            .autoCheckUpdates: .init(value: .bool(false), isForced: false),
        ])
        XCTAssertEqual(policy.managedKeys, [.defaultSaveDirectory, .autoCheckUpdates])
        XCTAssertEqual(policy.lockedKeys, [.defaultSaveDirectory])
        XCTAssertTrue(policy.isLocked(.defaultSaveDirectory))
        XCTAssertTrue(policy.isManaged(.autoCheckUpdates))
        XCTAssertFalse(policy.isLocked(.autoCheckUpdates))
    }

    func testJSONReaderFeedsThePolicy() throws {
        let json = """
        {"defaultSaveDirectory": "/srv/downloads",
         "maxDownloadBytesPerSec": 5242880,
         "auditLogEnabled": true,
         "remoteTrustedProxies": ["127.0.0.1", "10.0.0.0/8"],
         "somethingWeDoNotSupport": "ignored"}
        """
        let path = NSTemporaryDirectory() + "goel-policy-\(UUID().uuidString).json"
        try Data(json.utf8).write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }

        let reader = try XCTUnwrap(JSONManagedPreferenceReader(contentsOfFile: path))
        let policy = ManagedPolicy.read(using: reader)
        let effective = policy.apply(to: AppSettings())

        XCTAssertEqual(effective.defaultSaveDirectory, "/srv/downloads")
        XCTAssertTrue(effective.auditLogEnabled)
        XCTAssertEqual(effective.remoteTrustedProxies, ["127.0.0.1", "10.0.0.0/8"])
        XCTAssertEqual(policy.managedKeys.count, 4, "unknown keys must be dropped, not crash")
    }

    func testMissingPolicyFileMeansUnmanaged() {
        XCTAssertNil(JSONManagedPreferenceReader(contentsOfFile: "/nonexistent/goel-policy.json"))
    }

    // Backs the Deploy/README.md promise: the audit file records a host, nothing more identifying.

    func testRedactedHostDropsPathQueryAndCredentials() {
        let locator = "https://user:s3cr3t@files.example.com/private/report.pdf?token=AKIAEXAMPLE&sig=deadbeef"
        XCTAssertEqual(AuditEvent.redactedHost(from: locator), "files.example.com")
        XCTAssertEqual(AuditEvent.redactedScheme(from: locator), "https")
    }

    func testMagnetLinksRecordNoInfoHash() {
        let locator = "magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567&dn=Something"
        XCTAssertEqual(AuditEvent.redactedHost(from: locator), "magnet")
    }

    func testUnparseableLocatorFallsBackToAConstant() {
        // The fallback must be a constant, never the raw string — otherwise a locator that fails to parse smuggles itself into the file whole.
        XCTAssertEqual(AuditEvent.redactedHost(from: "not a url at all"), "unknown")
        XCTAssertEqual(AuditEvent.redactedHost(from: ""), "unknown")
    }

    func testAuditLineContainsNoPartOfTheFullURL() throws {
        let secretURL = "https://files.example.com/private/quarterly-results.pdf?token=AKIAEXAMPLE"
        let source = try XCTUnwrap(DownloadSource.parse(secretURL))
        let task = DownloadTask(source: source, name: "quarterly-results.pdf",
                                saveDirectory: "/Users/Shared/Downloads",
                                totalBytes: 1024, bytesDownloaded: 1024,
                                status: .completed)
        let line = try AuditEvent(action: .completed, task: task, user: "a.patel").jsonLine()

        XCTAssertTrue(line.contains("files.example.com"))
        XCTAssertFalse(line.contains("token=AKIAEXAMPLE"), "query string leaked into the audit log")
        XCTAssertFalse(line.contains("AKIAEXAMPLE"), "credential leaked into the audit log")
        XCTAssertFalse(line.contains("quarterly-results.pdf"), "URL path leaked into the audit log")
        XCTAssertFalse(line.contains("/private/"), "URL path leaked into the audit log")
        XCTAssertTrue(line.contains("/Users/Shared/Downloads"), "destination directory is recorded")
        XCTAssertTrue(line.contains("\"user\":\"a.patel\""))
        XCTAssertTrue(line.hasSuffix("\n"), "JSONL rows are newline-terminated")
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1, "a record must occupy exactly one line")
    }

    func testFailedRecordCarriesAStableTokenNotTheServerMessage() throws {
        let source = try XCTUnwrap(DownloadSource.parse("https://cdn.example.com/big.iso"))
        let task = DownloadTask(source: source, name: "big.iso", saveDirectory: "/tmp",
                                status: .failed(.httpStatus(403)))
        let event = AuditEvent(action: .failed, task: task, user: "svc")
        XCTAssertEqual(event.outcome, "http-403")
        let line = try event.jsonLine()
        XCTAssertFalse(line.contains("Forbidden"))
    }

    func testAddedRecordsZeroBytes() throws {
        let source = try XCTUnwrap(DownloadSource.parse("https://cdn.example.com/big.iso"))
        let task = DownloadTask(source: source, name: "big.iso", saveDirectory: "/tmp",
                                bytesDownloaded: 999)
        XCTAssertEqual(AuditEvent(action: .added, task: task).bytes, 0)
    }

    func testDisabledAuditLogWritesNothing() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = AuditLog(configuration: .init(isEnabled: false, directory: directory))
        await log.record(sampleEvent())
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(AuditLog.fileName).path),
            "the default (off) configuration must not create a file")
    }

    func testEnabledAuditLogAppendsOneLinePerEvent() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = AuditLog(configuration: .init(isEnabled: true, directory: directory))
        await log.record(sampleEvent())
        await log.record(sampleEvent())
        await log.record(sampleEvent())

        let url = directory.appendingPathComponent(AuditLog.fileName)
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        for line in lines {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8)),
                             "every row must be independently parseable JSON")
        }
    }

    func testAuditLogRotatesAndPrunes() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = AuditLog(configuration: .init(isEnabled: true, directory: directory,
                                                maxFileBytes: 1, keepFiles: 2,
                                                retentionDays: 0))
        for _ in 0..<40 { await log.record(sampleEvent()) }

        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let archives = names.filter { $0.hasPrefix("goel-audit-") }
        XCTAssertTrue(names.contains(AuditLog.fileName), "the live file must still exist")
        XCTAssertLessThanOrEqual(archives.count, 2, "keepFiles must bound the archives")
        XCTAssertGreaterThan(archives.count, 0, "rotation must actually have happened")
    }

    func testAuditConfigurationFromSettings() {
        var settings = AppSettings()
        settings.auditLogEnabled = true
        settings.auditLogDirectory = "/var/log/goel"
        settings.auditLogKeepFiles = 24
        settings.auditLogRetentionDays = 365
        settings.auditLogMaxFileMegabytes = 16

        let config = AuditLog.Configuration(settings: settings)
        XCTAssertTrue(config.isEnabled)
        XCTAssertEqual(config.directory?.path, "/var/log/goel")
        XCTAssertEqual(config.keepFiles, 24)
        XCTAssertEqual(config.retentionDays, 365)
        XCTAssertEqual(config.maxFileBytes, 16 * 1024 * 1024)

        settings.auditLogDirectory = "   "
        XCTAssertNil(AuditLog.Configuration(settings: settings).directory)
    }

    func testFreeAttemptsAreNotPenalised() {
        var throttle = RemoteLoginThrottle(freeAttempts: 3, baseDelay: 10)
        let now = Date()
        for _ in 0..<3 {
            XCTAssertEqual(throttle.check("10.0.0.5", now: now), .allowed)
            XCTAssertEqual(throttle.recordFailure("10.0.0.5", now: now), 0)
        }
        XCTAssertEqual(throttle.check("10.0.0.5", now: now), .allowed)
    }

    func testBackoffDoublesAndIsCapped() {
        var throttle = RemoteLoginThrottle(freeAttempts: 2, baseDelay: 10, maxDelay: 40)
        let now = Date()
        for _ in 0..<2 { throttle.recordFailure("10.0.0.5", now: now) }
        XCTAssertEqual(throttle.recordFailure("10.0.0.5", now: now), 10)
        XCTAssertEqual(throttle.recordFailure("10.0.0.5", now: now), 20)
        XCTAssertEqual(throttle.recordFailure("10.0.0.5", now: now), 40)
        XCTAssertEqual(throttle.recordFailure("10.0.0.5", now: now), 40)
    }

    func testBlockedClientIsRefusedUntilTheLockoutExpires() {
        var throttle = RemoteLoginThrottle(freeAttempts: 1, baseDelay: 30)
        let start = Date()
        throttle.recordFailure("10.0.0.5", now: start)
        throttle.recordFailure("10.0.0.5", now: start)

        guard case .blocked(let retryAfter) = throttle.check("10.0.0.5", now: start) else {
            return XCTFail("expected the client to be locked out")
        }
        XCTAssertEqual(retryAfter, 30)
        XCTAssertEqual(throttle.check("10.0.0.5", now: start.addingTimeInterval(29)),
                       .blocked(retryAfter: 1))
        XCTAssertEqual(throttle.check("10.0.0.5", now: start.addingTimeInterval(31)), .allowed)
    }

    /// The reason this is per-IP at all: one attacker must not be able to lock everybody else out of the portal.
    func testOneAttackerCannotLockOutOtherClients() {
        var throttle = RemoteLoginThrottle(freeAttempts: 1, baseDelay: 60)
        let now = Date()
        for _ in 0..<10 { throttle.recordFailure("203.0.113.9", now: now) }

        XCTAssertEqual(throttle.check("10.0.0.5", now: now), .allowed)
        guard case .blocked = throttle.check("203.0.113.9", now: now) else {
            return XCTFail("the guessing address should be the one that is blocked")
        }
    }

    func testCorrectPasswordClearsTheRecord() {
        var throttle = RemoteLoginThrottle(freeAttempts: 1, baseDelay: 60)
        let now = Date()
        throttle.recordFailure("10.0.0.5", now: now)
        throttle.recordFailure("10.0.0.5", now: now)
        throttle.recordSuccess("10.0.0.5")
        XCTAssertEqual(throttle.check("10.0.0.5", now: now), .allowed)
        XCTAssertEqual(throttle.failureCount("10.0.0.5"), 0)
    }

    /// Addresses arrive from the socket layer in several shapes; they must land in one bucket or the throttle counts the same attacker several times.
    func testAddressFormsShareOneBucket() {
        var throttle = RemoteLoginThrottle(freeAttempts: 1, baseDelay: 60)
        let now = Date()
        throttle.recordFailure("10.0.0.5", now: now)
        throttle.recordFailure("::ffff:10.0.0.5", now: now)
        guard case .blocked = throttle.check("10.0.0.5:54321", now: now) else {
            return XCTFail("IPv4-mapped and host:port forms must share a bucket")
        }
    }

    func testUnknownAddressesShareTheSafeBucket() {
        var throttle = RemoteLoginThrottle(freeAttempts: 1, baseDelay: 60)
        let now = Date()
        throttle.recordFailure("", now: now)
        throttle.recordFailure("", now: now)
        guard case .blocked = throttle.check("", now: now) else {
            return XCTFail("an unidentifiable client must be throttled, not exempted")
        }
    }

    /// Re-applying settings must not hand a locked-out attacker a clean slate.
    func testPolicyChangeKeepsExistingFailureRecords() {
        var throttle = RemoteLoginThrottle(freeAttempts: 1, baseDelay: 60)
        let now = Date()
        throttle.recordFailure("10.0.0.5", now: now)
        throttle.recordFailure("10.0.0.5", now: now)
        throttle.adoptPolicy(of: RemoteLoginThrottle(freeAttempts: 9, baseDelay: 1))
        guard case .blocked = throttle.check("10.0.0.5", now: now) else {
            return XCTFail("adopting a new policy must not forgive an active lockout")
        }
    }

    func testHeaderSSOIsOffByDefault() {
        let request = loginlessRequest(headers: ["x-forwarded-user": "a.patel"])
        XCTAssertNil(RemoteAuthService.trustedIdentity(request, client: "127.0.0.1",
                                                       policy: TrustedIdentityHeaderPolicy()))
    }

    /// An empty trusted-proxy list means "trust nobody" — the single most important default in this feature.
    func testEnabledButWithoutTrustedProxiesRefusesTheHeader() {
        let policy = TrustedIdentityHeaderPolicy(isEnabled: true, trustedProxies: [])
        XCTAssertFalse(policy.isEffective)
        let request = loginlessRequest(headers: ["x-forwarded-user": "a.patel"])
        XCTAssertNil(RemoteAuthService.trustedIdentity(request, client: "127.0.0.1", policy: policy))
    }

    /// Once the proxy presents its shared secret the peer address is the remaining discriminator: honoured inside the trusted set, refused outside it or from an undeterminable address.
    func testHeaderIsHonouredOnlyFromATrustedAddress() {
        let policy = TrustedIdentityHeaderPolicy(isEnabled: true,
                                                 trustedProxies: ["127.0.0.1", "10.20.0.0/16"],
                                                 sharedSecret: "proxy-secret")
        let request = loginlessRequest(headers: [
            "x-forwarded-user": "a.patel",
            TrustedIdentityHeaderPolicy.sharedSecretHeader: "proxy-secret",
        ])

        XCTAssertEqual(RemoteAuthService.trustedIdentity(request, client: "127.0.0.1", policy: policy),
                       "a.patel")
        XCTAssertEqual(RemoteAuthService.trustedIdentity(request, client: "10.20.7.3", policy: policy),
                       "a.patel")
        XCTAssertNil(RemoteAuthService.trustedIdentity(request, client: "203.0.113.9", policy: policy),
                     "an untrusted peer must not be able to assert an identity")
        XCTAssertNil(RemoteAuthService.trustedIdentity(request, client: "", policy: policy),
                     "an unknown peer address must not be trusted")
    }

    /// A trusted peer address alone isn't proof of proxy origin — everything else on the host can dial 127.0.0.1 too, so without the shared secret it must buy nothing.
    func testTrustedAddressWithoutTheProxySecretIsRefused() {
        let policy = TrustedIdentityHeaderPolicy(isEnabled: true, trustedProxies: ["127.0.0.1"],
                                                 sharedSecret: "proxy-secret")
        let unsigned = loginlessRequest(headers: ["x-forwarded-user": "a.patel"])
        XCTAssertNil(RemoteAuthService.trustedIdentity(unsigned, client: "127.0.0.1", policy: policy),
                     "a trusted address without the proxy secret must not assert an identity")

        let wrongSecret = loginlessRequest(headers: [
            "x-forwarded-user": "a.patel",
            TrustedIdentityHeaderPolicy.sharedSecretHeader: "proxy-secre",
        ])
        XCTAssertNil(RemoteAuthService.trustedIdentity(wrongSecret, client: "127.0.0.1", policy: policy),
                     "a wrong proxy secret must not assert an identity")
    }

    func testMissingOrHostileHeaderValuesAreRefused() {
        let policy = TrustedIdentityHeaderPolicy(isEnabled: true, trustedProxies: ["127.0.0.1"],
                                                 sharedSecret: "proxy-secret")
        func signed(_ user: String?) -> RemoteRequest {
            var headers = [TrustedIdentityHeaderPolicy.sharedSecretHeader: "proxy-secret"]
            if let user { headers["x-forwarded-user"] = user }
            return loginlessRequest(headers: headers)
        }
        XCTAssertNil(RemoteAuthService.trustedIdentity(signed(nil),
                                                       client: "127.0.0.1", policy: policy))
        XCTAssertNil(RemoteAuthService.trustedIdentity(signed(""),
                                                       client: "127.0.0.1", policy: policy))
        XCTAssertNil(RemoteAuthService.trustedIdentity(signed("   "),
                                                       client: "127.0.0.1", policy: policy),
                     "a whitespace-only identity is empty once trimmed")
        // CRLF is already eaten by the request parser as a header break, so the interesting case is a control byte that survives into the value.
        XCTAssertNil(RemoteAuthService.trustedIdentity(signed("a.patel\u{01}admin"),
                                                       client: "127.0.0.1", policy: policy),
                     "control characters are a smuggling attempt, refused not sanitised")
        XCTAssertEqual(RemoteAuthService.trustedIdentity(signed("a.patel"),
                                                         client: "127.0.0.1", policy: policy),
                       "a.patel")
    }

    func testCIDRAndAddressNormalisation() {
        XCTAssertTrue(IPMatcher.matches("10.20.7.3", any: ["10.20.0.0/16"]))
        XCTAssertFalse(IPMatcher.matches("10.21.7.3", any: ["10.20.0.0/16"]))
        XCTAssertTrue(IPMatcher.matches("::ffff:127.0.0.1", any: ["127.0.0.1"]))
        XCTAssertTrue(IPMatcher.matches("fe80::1%en0", any: ["fe80::1"]))
        XCTAssertTrue(IPMatcher.matches("192.168.1.9", any: ["0.0.0.0/0"]))
        XCTAssertFalse(IPMatcher.matches("192.168.1.9", any: []))
        XCTAssertFalse(IPMatcher.matches("", any: ["192.168.1.9"]))
        XCTAssertFalse(IPMatcher.matches("192.168.1.9", any: ["192.168.1.9/33"]),
                       "a malformed prefix length must not match")
    }

    func testOldSettingsBlobDecodesToSafeDefaults() throws {
        let legacy = Data(#"{"remotePort":8899,"theme":"frost-dark"}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: legacy)

        XCTAssertFalse(settings.remoteTLSEnabled)
        XCTAssertEqual(settings.remoteTLSIdentityPath, "")
        XCTAssertFalse(settings.remoteTrustedHeaderAuthEnabled)
        XCTAssertEqual(settings.remoteTrustedProxies, [])
        XCTAssertEqual(settings.remoteLoginMaxAttempts, 5)
        XCTAssertFalse(settings.auditLogEnabled, "the audit log must be off for existing users")
        XCTAssertEqual(settings.auditLogDirectory, "")
    }

    func testDefaultSecurityBundleIsThePreHardeningPosture() {
        let security = RemotePortalSecurity(settings: AppSettings())
        XCTAssertFalse(security.tlsEnabled)
        XCTAssertFalse(security.sso.isEnabled)
        XCTAssertFalse(security.sso.isEffective)
        XCTAssertEqual(security.throttle.freeAttempts, 5)
    }

    private func makeScratchDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("goel-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sampleEvent() -> AuditEvent {
        AuditEvent(action: .completed, user: "tester", host: "cdn.example.com",
                   scheme: "https", kind: "http", bytes: 4096,
                   destination: "/tmp/downloads", taskID: UUID().uuidString)
    }

    private func loginlessRequest(headers: [String: String]) -> RemoteRequest {
        var raw = "GET / HTTP/1.1\r\nHost: localhost\r\n"
        for (key, value) in headers { raw += "\(key): \(value)\r\n" }
        raw += "\r\n"
        return RemoteRequest(raw: Data(raw.utf8))
    }
}
