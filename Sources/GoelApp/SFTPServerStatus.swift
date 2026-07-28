import Foundation
import Network
import SwiftUI
import GoelCore

// Server-status diagnostics go through ``GoelLog/app``: a failure here is non-fatal, so the
// "why" goes to the unified log — and the hostname travels as a `.private` field.

/// Live reachability + lightweight metadata for a saved SFTP server. Reachability and IP are
/// deliberately unauthenticated (TCP connect + DNS); only OS detection authenticates, and lazily.
enum ServerReachability: Equatable {
    case unknown   // not yet probed
    case online    // TCP connect to the SSH port succeeded
    case offline   // connect failed / timed out

    var tint: Color {
        switch self {
        case .unknown: return .secondary
        case .online: return Theme.green
        case .offline: return Theme.red
        }
    }

    var help: String {
        switch self {
        case .unknown: return "Checking…"
        case .online: return "Online"
        case .offline: return "Offline"
        }
    }
}

/// Everything the sidebar knows about one server beyond its saved fields.
struct ServerMeta: Equatable {
    var reachability: ServerReachability = .unknown
    /// The resolved numeric address, e.g. "192.168.1.20".
    var ip: String?
    /// Round-trip time of the last successful TCP connect, in milliseconds.
    var latencyMS: Int?
    /// Why the last probe read as offline (e.g. "Connection refused", "Timed
    /// out"), for the sidebar tooltip. Nil when online or not yet probed.
    var offlineDetail: String?
    /// The detected operating system, once a browser session has read it.
    var os: ServerOS?
}

/// A detected server OS, parsed from `/etc/os-release`. Real distro logos would need bundled
/// assets; for now the common ones map to a tint + generic SF Symbol plus the `pretty` name.
struct ServerOS: Equatable {
    /// The `os-release` `ID`, lowercased — "ubuntu", "debian", "alpine", …
    var id: String
    /// `PRETTY_NAME` when present, e.g. "Ubuntu 22.04.3 LTS"; else a titrecased id.
    var pretty: String

    /// A short chip label: the pretty name with the "GNU/Linux" token dropped (Debian/Kali carry it
    /// mid-string) and doubled spaces collapsed, so the sidebar chip stays compact.
    var label: String {
        pretty
            .replacingOccurrences(of: "GNU/Linux ", with: "")
            .replacingOccurrences(of: " GNU/Linux", with: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    var symbol: String {
        switch id {
        case "ubuntu", "debian", "raspbian", "linuxmint", "pop": return "shippingbox"
        case "alpine", "arch", "manjaro", "fedora", "centos", "rhel", "rocky", "almalinux",
             "opensuse", "suse", "gentoo", "void", "nixos", "kali": return "shippingbox"
        case "freebsd", "openbsd", "netbsd": return "shippingbox"
        case "darwin", "macos": return "apple.logo"
        default: return "server.rack"
        }
    }

    var tint: Color {
        switch id {
        case "ubuntu": return Theme.orange
        case "debian", "raspbian", "centos", "rhel", "rocky", "almalinux", "redhat":
            return Theme.red
        case "fedora", "alpine", "arch", "manjaro", "nixos": return Theme.accent
        case "opensuse", "suse", "gentoo": return Theme.green
        case "darwin", "macos": return .secondary
        default: return Theme.indigo
        }
    }

    /// Parse the contents of an `/etc/os-release` file. Returns nil when neither an
    /// `ID` nor a `PRETTY_NAME` is present (so a wrong/empty file isn't shown).
    static func parse(osRelease text: String) -> ServerOS? {
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            // Strip one layer of surrounding quotes (os-release quotes values with spaces). A file
            // truncated mid-value may lack the closing quote, so drop a dangling opener rather than render it.
            if value.count >= 2, let first = value.first, (first == "\"" || first == "'"),
               value.last == first {
                value = String(value.dropFirst().dropLast())
            } else if let first = value.first, first == "\"" || first == "'" {
                value = String(value.dropFirst())
            }
            // Untrusted, server-supplied text rendered in the sidebar — cap it so a
            // malformed/hostile os-release can't produce an absurdly long chip.
            values[key] = String(value.prefix(200))
        }
        let id = (values["ID"] ?? "").lowercased()
        let pretty = values["PRETTY_NAME"] ?? values["NAME"] ?? ""
        guard !id.isEmpty || !pretty.isEmpty else { return nil }
        let display = pretty.isEmpty ? id.capitalized : pretty
        return ServerOS(id: id.isEmpty ? display.lowercased() : id, pretty: display)
    }
}

// MARK: - Unauthenticated reachability + DNS

/// A one-shot TCP reachability + DNS-resolution probe for the sidebar's live indicator. No SSH
/// handshake, no auth — just "is the port answering, and what does the host resolve to".
enum SFTPReachability {

    /// Connect to `host:port` over TCP and report whether it became ready within
    /// `timeout`, plus the round-trip time on success. Never authenticates.
    static func probe(host: String, port: Int, timeout: TimeInterval = 4) async
        -> (reachable: Bool, latencyMS: Int?, detail: String?) {
        guard !host.isEmpty else { return (false, nil, "No host") }
        let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: max(1, port))) ?? 22
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let start = Date()
        let once = OnceFlag()

        return await withCheckedContinuation { cont in
            @Sendable func finish(_ ok: Bool, _ detail: String?) {
                guard once.claim() else { return }
                let ms = ok ? Int((Date().timeIntervalSince(start) * 1000).rounded()) : nil
                if let detail {
                    GoelLog.app.debug("Server probe offline",
                                      .host(host), .count(port, label: "port"), .detail(detail))
                }
                conn.cancel()
                cont.resume(returning: (ok, ms, detail))
            }
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true, nil)
                case .failed(let error): finish(false, reason(error))
                case .cancelled: finish(false, nil)   // our own cancel loses the claim race
                default: break
                }
            }
            conn.start(queue: .global(qos: .utility))
            // A hard deadline: `NWConnection` can sit in `.preparing` for a long
            // time behind a black-hole firewall, so cap the wait ourselves.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                finish(false, "No response (timed out)")
            }
        }
    }

    /// A short, human reason for a failed TCP connect, so the sidebar can tell a
    /// refused port apart from an unreachable host apart from a DNS failure.
    private static func reason(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return "Connection refused"
            case .EHOSTUNREACH, .ENETUNREACH, .ENETDOWN: return "Host unreachable"
            case .ETIMEDOUT: return "Timed out"
            default: return "Connection failed"
            }
        case .dns: return "DNS lookup failed"
        default: return "Connection failed"
        }
    }

    /// Resolve `host` to a numeric address string (IPv4 preferred); the input unchanged if already
    /// an IP literal, nil if unresolvable. Runs the blocking `getaddrinfo` off the calling actor.
    static func resolveIP(host: String, timeout: TimeInterval = 4) async -> String? {
        guard !host.isEmpty else { return nil }
        let once = OnceFlag()
        // Race the blocking lookup against a deadline: `getaddrinfo` has no timeout, so a hung resolver
        // would pin a thread and stall the 20s sweep. On timeout the caller keeps its last good IP.
        return await withCheckedContinuation { cont in
            Task.detached(priority: .utility) {
                let ip = blockingResolveIP(host)
                if once.claim() { cont.resume(returning: ip) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if once.claim() { cont.resume(returning: nil) }
            }
        }
    }

    /// The blocking `getaddrinfo` lookup (IPv4 preferred). Returns the input unchanged for an IP
    /// literal, or nil if the host can't resolve. Must run off the calling actor.
    private static func blockingResolveIP(_ host: String) -> String? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let head = result else {
            GoelLog.app.debug("Host resolution failed",
                              .host(host), .detail(String(cString: gai_strerror(status))))
            return nil
        }
        defer { freeaddrinfo(head) }

        var best: String?
        var node: UnsafeMutablePointer<addrinfo>? = head
        while let current = node {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(current.pointee.ai_addr, current.pointee.ai_addrlen,
                           &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: buffer)
                if current.pointee.ai_family == AF_INET { return ip }  // prefer IPv4
                if best == nil { best = ip }                            // keep an IPv6 fallback
            }
            node = current.pointee.ai_next
        }
        return best
    }
}

/// A thread-safe "resume exactly once" latch for a `withCheckedContinuation` whose
/// completion can arrive from several callbacks (state handler + timeout).
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    /// True the first time it's called, false every time after.
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
