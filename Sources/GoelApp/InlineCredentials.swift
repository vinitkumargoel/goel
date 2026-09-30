import Foundation
import GoelCore

/// `https://user:pass@host/file` — the parser strips the userinfo so it never reaches the task
/// database, exports or the portal. Finding it is done here; saving it to the Keychain's per-host
/// logins is the manager's (``DownloadManager/adoptInlineCredentials(_:replaceExisting:)``), at
/// the moment the user commits to the download.
enum InlineCredentials {

    struct Found: Equatable {
        var host: String
        var username: String
        var password: String
        var isTLS: Bool
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

    /// The lines that carry a login, for ``DownloadManager/adoptInlineCredentials(_:replaceExisting:)``.
    static func linesWithLogins(in rawLines: String) -> [String] {
        rawLines.split(separator: "\n").map(String.init).filter { find(in: $0) != nil }
    }

    /// Rebuilds `scheme://user:pass@host/…` from a browser capture's decoded `Authorization`, so it goes
    /// through the same adoption (HTTPS only, never over an existing login) as a typed link.
    static func line(for url: URL, authorization: String) -> String? {
        guard let host = url.host?.lowercased(),
              let found = decode(authorization: authorization, host: host, isTLS: url.scheme?.lowercased() == "https"),
              var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        comps.user = found.username
        comps.password = found.password
        return comps.string
    }
}
