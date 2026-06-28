import Foundation

/// User-facing, persistable configuration that drives the scheduler.
///
/// It holds the list of switchable traffic profiles, which one is active, the
/// "snail" speed-limit toggle (when **off**, byte/sec caps are lifted — i.e.
/// unlimited speed — while the connection/simultaneous limits still apply), and
/// the default save folder used when a download is added without an explicit one.
///
/// It is a plain value type so it can be copied, diffed, encoded to disk, and
/// safely handed across isolation boundaries.
public struct AppSettings: Codable, Sendable, Hashable {

    /// All selectable profiles (defaults to Low / Medium / High).
    public var profiles: [TrafficProfile]

    /// The `name` of the currently selected profile.
    public var selectedProfileName: String

    /// The "snail" flag. When `false`, speed limiting is disabled and the
    /// effective profile reports unlimited download/upload byte rates.
    public var speedLimitEnabled: Bool

    /// Where new downloads are saved when no directory is supplied.
    public var defaultSaveDirectory: String

    public init(
        profiles: [TrafficProfile] = TrafficProfile.defaults,
        selectedProfileName: String = TrafficProfile.medium.name,
        speedLimitEnabled: Bool = true,
        defaultSaveDirectory: String = AppSettings.systemDownloadsDirectory
    ) {
        self.profiles = profiles
        self.selectedProfileName = selectedProfileName
        self.speedLimitEnabled = speedLimitEnabled
        self.defaultSaveDirectory = defaultSaveDirectory
    }

    /// The currently selected profile, falling back to the first available (or
    /// `.medium`) if the stored name no longer resolves.
    public var selectedProfile: TrafficProfile {
        profiles.first { $0.name == selectedProfileName }
            ?? profiles.first
            ?? .medium
    }

    /// The profile actually applied to the engines. Identical to
    /// ``selectedProfile`` except that, when ``speedLimitEnabled`` is `false`,
    /// the download/upload byte caps are forced to `0` (unlimited). The
    /// simultaneous-download, connection and metadata caps are never touched by
    /// the snail — those are queue policy, not bandwidth.
    public var effectiveProfile: TrafficProfile {
        guard !speedLimitEnabled else { return selectedProfile }
        var profile = selectedProfile
        profile.maxDownloadBytesPerSec = 0
        profile.maxUploadBytesPerSec = 0
        return profile
    }

    /// The user's Downloads folder, or the temporary directory if it can't be
    /// located.
    public static var systemDownloadsDirectory: String {
        FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask)
            .first?
            .path
            ?? NSTemporaryDirectory()
    }
}
