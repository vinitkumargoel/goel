import Foundation

/// Announce-URL lists as trackerslist.org and friends publish them: one URL per line, blank lines between.
public enum TrackerList {
    private static let schemes: Set<String> = ["udp", "http", "https", "ws", "wss"]

    /// A list fetched from the network is capped at this; real lists are a few KB.
    public static let maxListBytes = 2 * 1024 * 1024

    /// `publicOnly` (lists fetched from the network) also refuses private-range hosts: a hostile
    /// list must not point every torrent at the LAN. Loopback, unspecified and link-local hosts
    /// are refused always — no real tracker lives there, and announcing to them probes this Mac.
    public static func isValidAnnounceURL(_ raw: String, publicOnly: Bool = false) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 500,
              let components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(), schemes.contains(scheme),
              let host = components.host, !host.isEmpty
        else { return false }
        guard !text.contains(where: { $0.isWhitespace }) else { return false }
        return isAcceptableHost(host, publicOnly: publicOnly)
    }

    static func isAcceptableHost(_ host: String, publicOnly: Bool) -> Bool {
        let bare = NetworkGuard.bareHost(host)
        if NetworkGuard.isLoopbackOrUnspecified(bare) || NetworkGuard.isLinkLocal(bare) { return false }
        guard publicOnly else { return true }
        if bare.hasSuffix(".local") || bare.hasSuffix(".lan") || bare.hasSuffix(".internal")
            || bare.hasSuffix(".home.arpa") || !bare.contains(".") && !bare.contains(":") {
            return false
        }
        return NetworkGuard.addressClass(ofLiteral: bare) != .privateNetwork
    }

    /// Valid URLs from whitespace/comma-separated text, first occurrence wins, case-insensitive dedupe.
    public static func parse(_ text: String, publicOnly: Bool = false) -> [String] {
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ","))
        var seen: Set<String> = []
        var out: [String] = []
        for token in text.components(separatedBy: separators)
        where isValidAnnounceURL(token, publicOnly: publicOnly) {
            let key = token.lowercased()
            if seen.insert(key).inserted { out.append(token) }
        }
        return out
    }

    /// `existing` followed by whatever `additions` brings that it lacks.
    public static func merging(_ existing: [String], _ additions: [String]) -> [String] {
        var seen = Set(existing.map { $0.lowercased() })
        var out = existing
        for url in additions where seen.insert(url.lowercased()).inserted { out.append(url) }
        return out
    }

    /// A list refreshed less than a day ago is fresh enough.
    public static func needsRefresh(lastUpdated: Date?, now: Date = Date(),
                                    interval: TimeInterval = 24 * 60 * 60) -> Bool {
        guard let lastUpdated else { return true }
        return now.timeIntervalSince(lastUpdated) >= interval || now < lastUpdated
    }
}
