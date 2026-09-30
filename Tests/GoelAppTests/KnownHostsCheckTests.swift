import XCTest
import CryptoKit
@testable import GoelApp

final class KnownHostsCheckTests: XCTestCase {

    private let blob = Data((0..<51).map { UInt8($0) })
    private var blobB64: String { blob.base64EncodedString() }
    private var hex: String { SHA256.hash(data: blob).map { String(format: "%02x", $0) }.joined() }

    func testOpenSSHFingerprintMatchesSshKeygenFormat() {
        let expected = "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(KnownHostsCheck.openSSHFingerprint(hex: hex), expected)
        XCTAssertNil(KnownHostsCheck.openSSHFingerprint(hex: "abc"))
    }

    func testPlainAndBracketedNamesMatch() {
        let file = """
            # comment
            other.example ssh-rsa \(blobB64)
            nas.local,10.0.0.2 ssh-ed25519 \(blobB64)
            [nas.local]:2222 ecdsa-sha2-nistp256 \(blobB64)
            """
        XCTAssertEqual(KnownHostsCheck.matchingKeyType(knownHosts: file, host: "NAS.local", port: 22,
                                                       fingerprintHex: hex), "ssh-ed25519")
        XCTAssertEqual(KnownHostsCheck.matchingKeyType(knownHosts: file, host: "nas.local", port: 2222,
                                                       fingerprintHex: hex), "ecdsa-sha2-nistp256")
        XCTAssertNil(KnownHostsCheck.matchingKeyType(knownHosts: file, host: "nas.local", port: 22,
                                                     fingerprintHex: String(repeating: "0", count: 64)))
    }

    func testHashedNameMatchesAndRevokedNeverDoes() {
        let salt = Data((0..<20).map { UInt8($0 &* 7) })
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data("nas.local".utf8), using: SymmetricKey(data: salt))
        let hashed = "|1|\(salt.base64EncodedString())|\(Data(mac).base64EncodedString())"
        XCTAssertEqual(KnownHostsCheck.matchingKeyType(knownHosts: "\(hashed) ssh-ed25519 \(blobB64)",
                                                       host: "nas.local", port: 22, fingerprintHex: hex),
                       "ssh-ed25519")
        XCTAssertNil(KnownHostsCheck.matchingKeyType(knownHosts: "@revoked nas.local ssh-ed25519 \(blobB64)",
                                                     host: "nas.local", port: 22, fingerprintHex: hex))
    }
}
