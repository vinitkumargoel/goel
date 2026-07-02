import Foundation

/// One tracker's live state for a torrent, as reported by the engine for the
/// Details tab. Purely observational — nothing schedules off it.
public struct TorrentTracker: Codable, Sendable, Equatable, Hashable, Identifiable {
    /// How the last announce to this tracker went.
    public enum Status: Int, Codable, Sendable {
        case inactive = 0   // not yet contacted
        case updating = 1   // announce in flight
        case working  = 2   // announced / scraped OK
        case error    = 3   // last announce failed
    }

    /// The tracker's announce URL (also its stable identity within a torrent).
    public var url: String
    /// Announce tier (0 = primary; higher tiers are fallbacks).
    public var tier: Int
    /// Last status / error message, if any.
    public var message: String
    /// Swarm seeds reported by the tracker's scrape, or nil when unknown.
    public var seeds: Int?
    /// Swarm leechers reported by the tracker's scrape, or nil when unknown.
    public var leeches: Int?
    public var status: Status
    /// Whether the tracker has been successfully reached at least once.
    public var verified: Bool

    public var id: String { url }

    public init(url: String, tier: Int = 0, message: String = "",
                seeds: Int? = nil, leeches: Int? = nil,
                status: Status = .inactive, verified: Bool = false) {
        self.url = url
        self.tier = tier
        self.message = message
        self.seeds = seeds
        self.leeches = leeches
        self.status = status
        self.verified = verified
    }

    /// A short human label for the status, for the UI badge.
    public var statusLabel: String {
        switch status {
        case .working:  return "Working"
        case .updating: return "Updating"
        case .error:    return message.isEmpty ? "Error" : "Error"
        case .inactive: return "Idle"
        }
    }

    /// The host portion of the announce URL, for a compact display.
    public var host: String {
        URLComponents(string: url)?.host ?? url
    }
}
