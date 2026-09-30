import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// DNS rebinding defence: after a rebind, `evil.example` points at this socket and the browser
/// treats the portal as same-origin with the attacker — Origin equals Host, so only Host can tell.
/// Names a rebinding attacker cannot control pass (IP literals, localhost, mDNS `.local`, single
/// labels, this machine's name); anything else must be configured or come via a trusted proxy.
public enum RemoteHostPolicy {

    /// `GOEL_PORTAL_ALLOWED_HOSTS=goel.example.com,*.corp.example` — for a reverse proxy that passes
    /// the public Host through (Caddy/Traefik default). Environment, like the proxy secret.
    public static var allowedHostsFromEnvironment: [String] {
        parseList(ProcessInfo.processInfo.environment["GOEL_PORTAL_ALLOWED_HOSTS"] ?? "")
    }

    static func parseList(_ raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
    }

    public static func allows(hostHeader: String?, client: String,
                              security: RemotePortalSecurity) -> Bool {
        allows(headers: hostHeader.map { ["host": $0] } ?? [:], client: client, security: security)
    }

    /// `headers` keys are lower-case, as ``RemoteRequest`` stores them.
    public static func allows(headers: [String: String], client: String,
                              security: RemotePortalSecurity) -> Bool {
        // No Host = not a browser (HTTP/1.0 scripts); rebinding always arrives with one.
        guard let raw = headers["host"]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return true
        }
        if nameAllowed(raw, security: security) { return true }
        // A peer address alone is no proof: a loopback-listed proxy also relays a rebound local
        // browser. The proxy must show the shared secret, or forward a Host we would accept anyway.
        guard IPMatcher.matches(client, any: security.sso.trustedProxies) else { return false }
        let secret = security.sso.sharedSecret
        if !secret.isEmpty,
           let presented = headers[TrustedIdentityHeaderPolicy.sharedSecretHeader],
           RemoteRouter.constantTimeEquals(presented, secret) {
            return true
        }
        guard let forwarded = headers["x-forwarded-host"]?
                .split(separator: ",").first?.trimmingCharacters(in: .whitespaces),
              !forwarded.isEmpty else { return false }
        return nameAllowed(forwarded, security: security)
    }

    /// Names a rebinding attacker cannot choose, plus the configured ones.
    static func nameAllowed(_ raw: String, security: RemotePortalSecurity) -> Bool {
        guard let host = hostName(fromHeader: raw) else { return false }
        if isAddressLiteral(host) { return true }
        if host == "localhost" || host.hasSuffix(".localhost") { return true }
        // mDNS (Bonjour advertises the portal) and bare LAN names never come from public DNS.
        if host.hasSuffix(".local") || !host.contains(".") { return true }
        if machineNames.contains(host) { return true }
        return security.allowedHosts.contains(where: { matches(host, pattern: $0) })
    }

    /// Lower-cased name without port, brackets or trailing dot; nil for a malformed header.
    static func hostName(fromHeader raw: String) -> String? {
        var value = raw.lowercased()
        if value.hasPrefix("[") {
            guard let close = value.firstIndex(of: "]") else { return nil }
            // Only `:port` may follow the bracket — `[::1].evil.com` is a name, not a literal.
            let rest = value[value.index(after: close)...]
            if !rest.isEmpty {
                guard rest.first == ":", isPort(rest.dropFirst()) else { return nil }
            }
            value = String(value[value.index(after: value.startIndex)..<close])
            guard isAddressLiteral(value) else { return nil }
        } else if let colon = value.lastIndex(of: ":") {
            // Only one colon is legal outside brackets: host:port.
            guard value.filter({ $0 == ":" }).count == 1,
                  isPort(value[value.index(after: colon)...]) else { return nil }
            value = String(value[..<colon])
        }
        if value.hasSuffix(".") { value.removeLast() }
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({ $0.isASCII && !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return value
    }

    private static func isPort(_ text: Substring) -> Bool {
        !text.isEmpty && text.count <= 5 && text.allSatisfy(\.isASCII) && text.allSatisfy(\.isNumber)
    }

    static func isAddressLiteral(_ host: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        let bare = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        return inet_pton(AF_INET, bare, &v4) == 1 || inet_pton(AF_INET6, bare, &v6) == 1
    }

    static func matches(_ host: String, pattern: String) -> Bool {
        let p = pattern.lowercased()
        if p.hasPrefix("*.") { return host.hasSuffix(String(p.dropFirst(1))) }
        return host == p
    }

    /// `gethostname`, not `ProcessInfo.hostName`: the latter can block on a reverse DNS lookup.
    static let machineNames: Set<String> = {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else { return [] }
        let name = String(cString: buffer).lowercased()
        guard !name.isEmpty else { return [] }
        let short = name.split(separator: ".").first.map(String.init) ?? name
        return [name, short, short + ".local"]
    }()
}
