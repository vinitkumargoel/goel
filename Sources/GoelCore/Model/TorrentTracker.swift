import Foundation

public struct TorrentTracker: Codable, Sendable, Equatable, Hashable, Identifiable {
    public enum Status: Int, Codable, Sendable {
        case inactive = 0
        case updating = 1
        case working  = 2
        case error    = 3
    }

    public var url: String
    /// 0 = primary; higher tiers are fallbacks.
    public var tier: Int
    public var message: String
    public var seeds: Int?
    public var leeches: Int?
    public var status: Status
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

    public var statusLabel: String {
        switch status {
        case .working:  return "Working"
        case .updating: return "Updating"
        case .error:    return message.isEmpty ? "Error" : message
        case .inactive: return "Idle"
        }
    }

    public var host: String {
        URLComponents(string: url)?.host ?? url
    }
}
