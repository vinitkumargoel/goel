import Foundation
import Network
import SwiftUI
import GoelCore

// Hostnames reach the unified log only as `.private` fields.

enum ServerReachability: Equatable {
    case unknown
    case online
    case offline

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

struct ServerMeta: Equatable {
    var reachability: ServerReachability = .unknown
    var ip: String?
    var latencyMS: Int?
    var offlineDetail: String?
    var os: ServerOS?
}

struct ServerOS: Equatable {
    var id: String
    var pretty: String

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

    static func parse(osRelease text: String) -> ServerOS? {
        var values: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            // The else branch catches a truncated os-release whose closing quote is missing.
            if value.count >= 2, let first = value.first, (first == "\"" || first == "'"),
               value.last == first {
                value = String(value.dropFirst().dropLast())
            } else if let first = value.first, first == "\"" || first == "'" {
                value = String(value.dropFirst())
            }
            // Untrusted server-supplied text rendered in the sidebar — cap the length.
            values[key] = String(value.prefix(200))
        }
        let id = (values["ID"] ?? "").lowercased()
        let pretty = values["PRETTY_NAME"] ?? values["NAME"] ?? ""
        guard !id.isEmpty || !pretty.isEmpty else { return nil }
        let display = pretty.isEmpty ? id.capitalized : pretty
        return ServerOS(id: id.isEmpty ? display.lowercased() : id, pretty: display)
    }
}

enum SFTPReachability {

    /// Never authenticates — TCP connect only.
    static func probe(host: String, port: Int, timeout: TimeInterval = 4) async
        -> (reachable: Bool, latencyMS: Int?, detail: String?) {
        guard !host.isEmpty else { return (false, nil, L10n.t("No host")) }
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
                case .cancelled: finish(false, nil)
                default: break
                }
            }
            conn.start(queue: .global(qos: .utility))
            // `NWConnection` sits in `.preparing` forever behind a black-hole firewall.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                finish(false, L10n.t("No response (timed out)"))
            }
        }
    }

    private static func reason(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return L10n.t("Connection refused")
            case .EHOSTUNREACH, .ENETUNREACH, .ENETDOWN: return L10n.t("Host unreachable")
            case .ETIMEDOUT: return L10n.t("Timed out")
            default: return L10n.t("Connection failed")
            }
        case .dns: return L10n.t("DNS lookup failed")
        default: return L10n.t("Connection failed")
        }
    }

    static func resolveIP(host: String, timeout: TimeInterval = 4) async -> String? {
        guard !host.isEmpty else { return nil }
        let once = OnceFlag()
        // `getaddrinfo` has no timeout; without this deadline a hung resolver pins a thread.
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

    /// Blocking — must run off the calling actor.
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
                if current.pointee.ai_family == AF_INET { return ip }
                if best == nil { best = ip }
            }
            node = current.pointee.ai_next
        }
        return best
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}
