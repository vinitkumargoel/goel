import Foundation

/// `GET /api/schedule`: the one download window the scheduler runs (downloads outside it are held),
/// with the traffic profile it switches to while open. Minutes are local time since midnight;
/// days use `Calendar` weekdays, 1 = Sunday … 7 = Saturday.
public struct RemoteScheduleState: Sendable, Codable, Equatable {
    public var enabled: Bool
    public var startMinute: Int
    public var endMinute: Int
    public var days: [Int]
    /// Empty = the window keeps whatever profile is active.
    public var profile: String
    /// The names `profile` may take, so the portal never offers one the server would refuse.
    public var profiles: [String]

    public init(enabled: Bool, startMinute: Int, endMinute: Int, days: [Int],
                profile: String, profiles: [String]) {
        self.enabled = enabled
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.days = days
        self.profile = profile
        self.profiles = profiles
    }
}

/// `POST /api/schedule`: every field optional; a missing one keeps its value.
public struct RemoteScheduleUpdate: Sendable, Equatable, Decodable {
    public var enabled: Bool?
    public var startMinute: Int?
    public var endMinute: Int?
    public var days: [Int]?
    public var profile: String?

    public init(enabled: Bool? = nil, startMinute: Int? = nil, endMinute: Int? = nil,
                days: [Int]? = nil, profile: String? = nil) {
        self.enabled = enabled
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.days = days
        self.profile = profile
    }

    /// Refuse rather than clamp: a typo'd minute must not quietly become midnight.
    public func refusal(against state: RemoteScheduleState) -> String? {
        let minutes = 0..<(24 * 60)
        if let startMinute, !minutes.contains(startMinute) { return "The start must be 00:00–23:59." }
        if let endMinute, !minutes.contains(endMinute) { return "The end must be 00:00–23:59." }
        if let days {
            if days.isEmpty { return "Pick at least one day." }
            if days.contains(where: { !(1...7).contains($0) }) { return "Days are 1 (Sunday) to 7 (Saturday)." }
        }
        if let profile, !profile.isEmpty, !state.profiles.contains(profile) {
            return "There is no traffic profile named “\(profile)”."
        }
        return nil
    }

    func apply(to settings: inout AppSettings) {
        if let enabled { settings.scheduleEnabled = enabled }
        if let startMinute { settings.scheduleStartMinute = startMinute }
        if let endMinute { settings.scheduleEndMinute = endMinute }
        if let days { settings.scheduleDays = Array(Set(days)).sorted() }
        if let profile { settings.scheduleProfileName = profile }
    }
}

extension RemoteScheduleState {
    init(_ settings: AppSettings) {
        self.init(enabled: settings.scheduleEnabled,
                  startMinute: settings.scheduleStartMinute,
                  endMinute: settings.scheduleEndMinute,
                  days: settings.scheduleDays,
                  profile: settings.scheduleProfileName,
                  profiles: settings.profiles.map(\.name))
    }
}
