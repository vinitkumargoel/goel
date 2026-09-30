import Foundation
import CryptoKit

/// Lets the first-contact prompt speak OpenSSH: `ssh-keygen -lf` prints `SHA256:<base64>`, not the hex
/// the bridge pins, and a key the user already trusts in `~/.ssh/known_hosts` is worth saying so.
enum KnownHostsCheck {

    /// "SHA256:q8Zb3…" from the bridge's lowercase hex SHA-256, or nil if it isn't 32 bytes of hex.
    static func openSSHFingerprint(hex: String) -> String? {
        guard let bytes = bytes(hex: hex), bytes.count == 32 else { return nil }
        let b64 = Data(bytes).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return "SHA256:" + b64
    }

    /// The key type ("ssh-ed25519") of a `known_hosts` entry for this endpoint whose key hashes to
    /// `fingerprintHex`, or nil. Handles plain, `[host]:port` and hashed (`|1|salt|hmac`) names;
    /// `@revoked`/`@cert-authority` lines are never a match.
    static func matchingKeyType(knownHosts: String, host: String, port: Int, fingerprintHex: String) -> String? {
        let want = fingerprintHex.lowercased()
        let name = port == 22 ? host.lowercased() : "[\(host.lowercased())]:\(port)"
        for raw in knownHosts.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("@") else { continue }
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 3,
                  names(fields[0], contain: name),
                  let blob = Data(base64Encoded: fields[2]) else { continue }
            let digest = SHA256.hash(data: blob).map { String(format: "%02x", $0) }.joined()
            if digest == want { return fields[1] }
        }
        return nil
    }

    /// Reads `~/.ssh/known_hosts` off the main thread's hot path only once per prompt; a missing file is no match.
    static func matchingKeyType(host: String, port: Int, fingerprintHex: String) -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/known_hosts")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return matchingKeyType(knownHosts: text, host: host, port: port, fingerprintHex: fingerprintHex)
    }

    private static func names(_ field: String, contain name: String) -> Bool {
        if field.hasPrefix("|1|") {
            let parts = field.split(separator: "|", omittingEmptySubsequences: true)
            guard parts.count == 3,
                  let salt = Data(base64Encoded: String(parts[1])),
                  let mac = Data(base64Encoded: String(parts[2])) else { return false }
            let code = HMAC<Insecure.SHA1>.authenticationCode(for: Data(name.utf8), using: SymmetricKey(data: salt))
            return Data(code) == mac
        }
        // Negated patterns ("!host") and wildcards are for ssh's own matching; exact names only here.
        return field.lowercased().split(separator: ",").contains { $0 == name }
    }

    private static func bytes(hex: String) -> [UInt8]? {
        let chars = Array(hex.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = nibble(chars[i]), let lo = nibble(chars[i + 1]) else { return nil }
            out.append(hi << 4 | lo)
            i += 2
        }
        return out
    }

    private static func nibble(_ c: UInt8) -> UInt8? {
        switch c {
        case 48...57: return c - 48
        case 97...102: return c - 87
        case 65...70: return c - 55
        default: return nil
        }
    }
}
