import Foundation
import GoelCore

/// `https://user:pass@host/file` — the parser strips the userinfo so it never reaches the task
/// database, exports or the portal. The secret is moved to the Keychain's per-host logins
/// instead, which the HTTP engine already sends (over TLS only) as `Authorization: Basic`.
enum InlineCredentials {

    struct Found: Equatable {
        var host: String
        var username: String
        var password: String
        var isTLS: Bool
    }

    /// Where the link came from decides whether it may replace a login the user already saved.
    enum Policy {
        /// Typed, pasted, dropped or accepted by the user: their latest word wins.
        case replace
        /// Arrived from a page through the browser extension: never overwrite a saved login.
        case keepExisting
    }

    enum Outcome: Equatable {
        case stored(host: String, isTLS: Bool)
        case keptExisting(host: String)
        case failed(host: String)
    }

    static func find(in line: String) -> Found? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = DownloadSource.parseWithCredentials(trimmed),
              let authorization = parsed.authorization,
              let host = URL(string: trimmed)?.host?.lowercased(), !host.isEmpty else { return nil }
        return decode(authorization: authorization, host: host,
                      isTLS: URL(string: trimmed)?.scheme?.lowercased() == "https")
    }

    /// Every distinct host with inline credentials, first occurrence wins.
    static func findAll(in rawLines: String) -> [Found] {
        var seen = Set<String>()
        return rawLines.split(separator: "\n").compactMap { line in
            guard let found = find(in: String(line)), seen.insert(found.host).inserted else { return nil }
            return found
        }
    }

    static func decode(authorization: String, host: String, isTLS: Bool) -> Found? {
        let prefix = "Basic "
        guard authorization.hasPrefix(prefix),
              let data = Data(base64Encoded: String(authorization.dropFirst(prefix.count))),
              let pair = String(data: data, encoding: .utf8),
              let colon = pair.firstIndex(of: ":") else { return nil }
        let user = String(pair[..<colon])
        guard !user.isEmpty else { return nil }
        return Found(host: host, username: user, password: String(pair[pair.index(after: colon)...]),
                     isTLS: isTLS)
    }

    @discardableResult
    static func adopt(_ found: Found, into store: any CredentialManaging, policy: Policy) -> Outcome {
        switch store.lookupCredential(forHost: found.host) {
        case .found(let user, let password):
            if user == found.username, password == found.password {
                return .stored(host: found.host, isTLS: found.isTLS)
            }
            if policy == .keepExisting { return .keptExisting(host: found.host) }
        case .denied, .failed:
            // An unreadable Keychain entry is not "nothing saved": don't write over what may be there.
            if policy == .keepExisting { return .keptExisting(host: found.host) }
        case .notFound:
            break
        }
        return store.storeCredential(username: found.username, password: found.password,
                                     host: found.host).didStore
            ? .stored(host: found.host, isTLS: found.isTLS)
            : .failed(host: found.host)
    }
}
