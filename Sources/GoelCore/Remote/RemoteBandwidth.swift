import Foundation

/// `GET /api/bandwidth`: the speed limiter and its traffic profiles, caps in bytes per second.
public struct RemoteBandwidthState: Sendable, Codable, Equatable {
    public struct Profile: Sendable, Codable, Equatable {
        public var name: String
        /// nil = unlimited (the profile stores 0 for that).
        public var downBytesPerSec: Int64?
        public var upBytesPerSec: Int64?

        public init(name: String, downBytesPerSec: Int64?, upBytesPerSec: Int64?) {
            self.name = name
            self.downBytesPerSec = downBytesPerSec
            self.upBytesPerSec = upBytesPerSec
        }

        init(_ profile: TrafficProfile) {
            name = profile.name
            downBytesPerSec = profile.maxDownloadBytesPerSec > 0 ? profile.maxDownloadBytesPerSec : nil
            upBytesPerSec = profile.maxUploadBytesPerSec > 0 ? profile.maxUploadBytesPerSec : nil
        }

        // Encode nil as an explicit `null`: the portal reads a missing key and "unlimited" differently.
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(downBytesPerSec, forKey: .downBytesPerSec)
            try c.encode(upBytesPerSec, forKey: .upBytesPerSec)
        }
    }

    /// Settings an administrator's configuration profile pins; a POST that changes one is refused.
    /// Forced *ceilings* are not listed: like the app's settings, a cap stays editable and is clamped.
    public enum LockedField: String, Sendable, Codable, CaseIterable {
        case enabled, selected
    }

    public var enabled: Bool
    public var selected: String
    public var profiles: [Profile]
    /// Extra to the portal contract; empty when nothing is managed.
    public var locked: [LockedField]

    public init(enabled: Bool, selected: String, profiles: [Profile], locked: [LockedField] = []) {
        self.enabled = enabled
        self.selected = selected
        self.profiles = profiles
        self.locked = locked
    }
}

/// `POST /api/bandwidth`: every field optional. A cap key that is absent keeps the cap; `null` means unlimited.
public struct RemoteBandwidthUpdate: Sendable, Equatable, Decodable {
    public struct ProfileCaps: Sendable, Equatable, Decodable {
        public var name: String
        /// Outer nil = leave alone, `.some(nil)` = unlimited.
        public var downBytesPerSec: Int64??
        public var upBytesPerSec: Int64??

        public init(name: String, downBytesPerSec: Int64?? = nil, upBytesPerSec: Int64?? = nil) {
            self.name = name
            self.downBytesPerSec = downBytesPerSec
            self.upBytesPerSec = upBytesPerSec
        }

        private enum CodingKeys: String, CodingKey { case name, downBytesPerSec, upBytesPerSec }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            downBytesPerSec = try Self.cap(c, .downBytesPerSec)
            upBytesPerSec = try Self.cap(c, .upBytesPerSec)
        }

        private static func cap(_ c: KeyedDecodingContainer<CodingKeys>,
                                _ key: CodingKeys) throws -> Int64?? {
            guard c.contains(key) else { return .none }
            if try c.decodeNil(forKey: key) { return .some(nil) }
            return .some(try c.decode(Int64.self, forKey: key))
        }
    }

    public var enabled: Bool?
    public var selected: String?
    public var profiles: [ProfileCaps]?

    public init(enabled: Bool? = nil, selected: String? = nil, profiles: [ProfileCaps]? = nil) {
        self.enabled = enabled
        self.selected = selected
        self.profiles = profiles
    }

    /// The first reason this update cannot apply to `state`, worded for the portal; nil = valid.
    public func problem(against state: RemoteBandwidthState) -> String? {
        let names = Set(state.profiles.map(\.name))
        if let selected, !names.contains(selected) {
            return "There is no traffic profile named ‘\(selected)’."
        }
        var seen = Set<String>()
        for caps in profiles ?? [] {
            guard names.contains(caps.name) else {
                return "There is no traffic profile named ‘\(caps.name)’."
            }
            guard seen.insert(caps.name).inserted else {
                return "‘\(caps.name)’ is listed more than once."
            }
            for case let value?? in [caps.downBytesPerSec, caps.upBytesPerSec] where value < 0 {
                return "A speed limit cannot be negative."
            }
        }
        return nil
    }

    /// The first locked setting this update would change, or nil. Re-sending a locked value unchanged is fine,
    /// so a portal that posts back the whole GET object is not refused for fields it did not touch.
    public func lockedChange(against state: RemoteBandwidthState) -> RemoteBandwidthState.LockedField? {
        let locked = Set(state.locked)
        if locked.contains(.enabled), let enabled, enabled != state.enabled { return .enabled }
        if locked.contains(.selected), let selected, selected != state.selected { return .selected }
        return nil
    }

    /// Applies to the user's *stored* settings; the manager re-overlays policy afterwards.
    func apply(to settings: inout AppSettings) {
        if let enabled { settings.speedLimitEnabled = enabled }
        if let selected { settings.selectedProfileName = selected }
        for caps in profiles ?? [] {
            guard let i = settings.profiles.firstIndex(where: { $0.name == caps.name }) else { continue }
            if let down = caps.downBytesPerSec { settings.profiles[i].maxDownloadBytesPerSec = max(0, down ?? 0) }
            if let up = caps.upBytesPerSec { settings.profiles[i].maxUploadBytesPerSec = max(0, up ?? 0) }
        }
    }
}

extension RemoteBandwidthState {
    /// Built from the effective (policy-overlaid) settings, so forced ceilings show as they apply.
    init(settings: AppSettings, policy: ManagedPolicy) {
        var locked: [LockedField] = []
        let ceilings = policy.isLocked(.maxDownloadBytesPerSec) || policy.isLocked(.maxUploadBytesPerSec)
        // A forced ceiling also forces the limiter on (see `ManagedPolicy.apply`).
        if policy.isLocked(.speedLimitEnabled) || ceilings { locked.append(.enabled) }
        if policy.isLocked(.selectedProfileName) { locked.append(.selected) }
        self.init(enabled: settings.speedLimitEnabled,
                  selected: settings.selectedProfile.name,
                  profiles: settings.profiles.map(Profile.init),
                  locked: locked)
    }
}

extension DownloadManager {
    public func bandwidthState() async -> RemoteBandwidthState? {
        RemoteBandwidthState(settings: settings, policy: managedPolicy)
    }

    public func updateBandwidth(_ update: RemoteBandwidthUpdate) async -> RemoteBandwidthState? {
        await apply { update.apply(to: &$0) }
        return await bandwidthState()
    }
}
