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

    /// The snail pill: "Speed: Unlimited" while the limit is off, "Low · 2 MB/s" while it is on (the
    /// download cap is the number people watch), or just the name when that cap is unlimited.
    static func pill(limitEnabled: Bool, profile: TrafficProfile) -> String {
        guard limitEnabled else { return L10n.t("Speed: Unlimited") }
        guard profile.maxDownloadBytesPerSec > 0 else { return profile.name }
        return L10n.t("%1$@ · %2$@", profile.name, rate(profile.maxDownloadBytesPerSec))
    }

    /// What choosing a profile changes right now. The queue limits always apply; the caps only
    /// while the snail is on (``AppSettings/effectiveProfile`` zeroes them), so they are marked off.
    /// "Low — up to 2 downloads at once, seed to 1.0×; speed cap ↓ 2 MB/s, ↑ 256 KB/s (off)"
    static func queueSummary(_ profile: TrafficProfile, limitEnabled: Bool) -> String {
        let caps = limitEnabled
            ? L10n.t("speed cap %@", limits(profile))
            : L10n.t("speed cap %@ (off)", limits(profile))
        return L10n.t("%1$@ — %2$@; %3$@", profile.name, queueLimits(profile), caps)
    }

    /// "up to 2 downloads at once, seed to 1.0×"
    static func queueLimits(_ profile: TrafficProfile) -> String {
        let ratio = profile.seedRatioLimit > 0
            ? L10n.t("seed to %@×", ratioString(profile.seedRatioLimit))
            : L10n.t("seed without limit")
        return L10n.t("up to %1$d downloads at once, %2$@", profile.maxSimultaneousDownloads, ratio)
    }

    /// The same, spoken: "up to 2 downloads at once, seed to ratio 1.0, speed limit off".
    static func spokenQueueSummary(_ profile: TrafficProfile, limitEnabled: Bool) -> String {
        let ratio = profile.seedRatioLimit > 0
            ? L10n.t("seed to ratio %@", ratioString(profile.seedRatioLimit))
            : L10n.t("seed without limit")
        return A11y.sentence(
            L10n.t("up to %d downloads at once", profile.maxSimultaneousDownloads),
            ratio,
            limitEnabled ? spokenLimits(profile) : L10n.t("speed limit off"))
    }

    private static func ratioString(_ ratio: Double) -> String {
        String(format: "%.1f", locale: DisplayFormat.appLocale, ratio)
    }
}
