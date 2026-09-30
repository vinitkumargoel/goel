import XCTest
import SSHBridge
@testable import GoelCore

/// Headless processes have no one to approve a first contact: only a pre-provisioned pin may let a credential leave.
final class ProvisionedHostKeysTests: XCTestCase {

    /// SHA-256 of nothing in particular: 32 bytes 0x00…0x1f.
    private static let hex = (0..<32).map { String(format: "%02x", $0) }.joined()
    private static let b64 = Data((0..<32).map { UInt8($0) }).base64EncodedString()
        .replacingOccurrences(of: "=", with: "")

    func testParsesOpenSSHStyleEntriesWithAndWithoutPorts() {
        let pins = ProvisionedHostKeys.parse(
            "nas.local=SHA256:\(Self.b64), Backup.example.com:2222=SHA256:\(Self.b64)=, [fe80::1]:22=\(Self.hex)")
        XCTAssertEqual(pins["nas.local:22"], Self.hex)
        XCTAssertEqual(pins["backup.example.com:2222"], Self.hex, "host is case-insensitive; padding tolerated")
        XCTAssertEqual(pins["fe80::1:22"], Self.hex)
    }

    func testIgnoresMalformedEntries() {
        let pins = ProvisionedHostKeys.parse("a=SHA256:tooShort,b=nothex,c:0=SHA256:\(Self.b64),=SHA256:\(Self.b64)")
        XCTAssertTrue(pins.isEmpty, "\(pins)")
    }

    func testLookupIsPerEndpoint() {
        let env = [ProvisionedHostKeys.variable: "nas.local:2200=SHA256:\(Self.b64)"]
        XCTAssertEqual(ProvisionedHostKeys.fingerprint(host: "NAS.local", port: 2200, environment: env), Self.hex)
        XCTAssertNil(ProvisionedHostKeys.fingerprint(host: "nas.local", port: 22, environment: env),
                     "a pin for one port must not vouch for another")
        XCTAssertNil(ProvisionedHostKeys.fingerprint(host: "nas.local", port: 2200, environment: [:]))
    }

    func testDisplayRoundTripsToTheOpenSSHForm() {
        XCTAssertEqual(ProvisionedHostKeys.displayFingerprint(hex: Self.hex), "SHA256:\(Self.b64)")
        XCTAssertEqual(ProvisionedHostKeys.hexFingerprint("SHA256:\(Self.b64)"), Self.hex)
    }

    func testUnpinnedMessageTellsTheOperatorHowToPin() {
        let message = ProvisionedHostKeys.unpinnedMessage(host: "nas.local", port: 2222, presented: Self.hex)
        XCTAssertTrue(message.contains("GOEL_SSH_FINGERPRINTS=nas.local:2222=SHA256:"), message)
        XCTAssertTrue(message.contains("SHA256:\(Self.b64)"), "the presented key is shown for out-of-band checking")
    }

    /// With no approver and no pin the client must refuse before authenticating — never trust-on-first-use.
    func testHeadlessWithoutAPinRefusesAndPinsNothing() async {
        let previous = HostKeyTrust.shared.approver
        HostKeyTrust.shared.approver = nil
        defer { HostKeyTrust.shared.approver = previous }
        let store = HostKeyStore(defaults: UserDefaults(suiteName: "goel.sec3.\(UUID().uuidString)")!)
        let client = SFTPClient(target: SFTPTarget(host: "127.0.0.1", port: 1, username: "u", password: "p"),
                                hostKeys: store)
        do {
            _ = try await client.list(".")
            XCTFail("an unpinned headless connect must refuse")
        } catch let e as SFTPError {
            XCTAssertEqual(e.kind, .hostKey)
            XCTAssertTrue(e.message.contains(ProvisionedHostKeys.variable), e.message)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(store.lookup(host: "127.0.0.1", port: 1), .none, "nothing may be learned on first use")
    }

    // MARK: - Error codes (FAIL-24) and probe notes (FAIL-16)

    func testSwiftSideFailuresKeepTheirKindAndWording() {
        let refused = SFTPError(kind: .hostKey, message: "pin it first")
        let result = SFTPResult(error: refused)
        XCTAssertEqual(result.code, Int32(GSB_ERR_HOSTKEY))
        XCTAssertEqual(result.asError(host: "h", port: 22, username: "u"), refused,
                       "the generic 'didn't present a host key' text must not replace the real reason")

        XCTAssertEqual(SFTPResult(error: SFTPError(kind: .connect, message: "x")).code, Int32(GSB_ERR_CONNECT))
        XCTAssertEqual(SFTPResult(error: SFTPError(kind: .auth, message: "x")).asError.kind, .auth)
    }

    func testHostKeyMismatchProbeNoteIsAWarningNotUnreachable() {
        let note = SFTPEngine.probeFailureNote(SFTPError(kind: .hostKeyMismatch, message: "The identity changed."))
        XCTAssertTrue(note.hasPrefix("Security warning"), note)
        XCTAssertEqual(SFTPEngine.probeFailureNote(SFTPError(kind: .connect, message: "Can't reach")), "Can't reach")
    }

    func testIdentityFailuresAreNotNetworkErrors() {
        if case .network = SFTPEngine.downloadError(SFTPError(kind: .hostKeyMismatch, message: "m")) {
            XCTFail("a changed host key is not a network error")
        }
        if case .network = SFTPEngine.downloadError(SFTPError(kind: .auth, message: "m")) {
            XCTFail("a refused sign-in is not a network error")
        }
        XCTAssertEqual(SFTPEngine.downloadError(SFTPError(kind: .connect, message: "m")), .network("m"))
    }
}
