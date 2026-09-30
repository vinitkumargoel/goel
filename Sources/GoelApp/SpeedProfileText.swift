import Foundation
import GoelCore

/// What a speed profile actually caps, in the words the status bar's tooltips, VoiceOver and
/// the snail pill use — read from the profile's real limits, never from its name.
enum SpeedProfileText {

    /// "2 MB/s", or "unlimited" for a cap of 0.
    static func rate(_ bytesPerSecond: Int64) -> String {
        bytesPerSecond > 0 ? Double(bytesPerSecond).speedString : L10n.t("unlimited")
    }

    /// "↓ 2 MB/s, ↑ 256 KB/s"
    static func limits(_ profile: TrafficProfile) -> String {
        L10n.t("↓ %1$@, ↑ %2$@", rate(profile.maxDownloadBytesPerSec), rate(profile.maxUploadBytesPerSec))
    }

    /// "Low — ↓ 2 MB/s, ↑ 256 KB/s": the profile button's tooltip and accessibility value.
    static func summary(_ profile: TrafficProfile) -> String {
        L10n.t("%1$@ — %2$@", profile.name, limits(profile))
    }

    /// The same, spoken: arrows read badly in VoiceOver.
    static func spokenLimits(_ profile: TrafficProfile) -> String {
        A11y.sentence(
            profile.maxDownloadBytesPerSec > 0
                ? L10n.t("download limit %@", A11y.speed(Double(profile.maxDownloadBytesPerSec)))
                : L10n.t("download unlimited"),
            profile.maxUploadBytesPerSec > 0
                ? L10n.t("upload limit %@", A11y.speed(Double(profile.maxUploadBytesPerSec)))
                : L10n.t("upload unlimited"))
    }

    /// The snail pill: "Unlimited" while the limit is off, "Low · 2 MB/s" while it is on (the
    /// download cap is the number people watch), or just the name when that cap is unlimited.
    static func pill(limitEnabled: Bool, profile: TrafficProfile) -> String {
        guard limitEnabled else { return L10n.t("Unlimited") }
        guard profile.maxDownloadBytesPerSec > 0 else { return profile.name }
        return L10n.t("%1$@ · %2$@", profile.name, rate(profile.maxDownloadBytesPerSec))
    }
}
