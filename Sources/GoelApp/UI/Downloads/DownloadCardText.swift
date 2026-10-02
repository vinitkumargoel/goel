import Foundation
import GoelCore

/// The words on a board card, kept out of the view so they can be tested.
enum DownloadCardText {

    /// Which colour a card's meta line takes.
    enum Tone: Equatable { case plain, accent, upload, info, warn, bad }

    /// The large card's line under the name: where it comes from and how big it is —
    /// "releases.ubuntu.com · 4.7 GB", "38 peers · 17 GB".
    static func largeMeta(_ task: DownloadTask) -> String {
        let origin: String
        if task.kind == .torrent {
            origin = task.connectionCount == 1 ? L10n.t("%d peer", 1) : L10n.t("%d peers", task.connectionCount)
        } else {
            origin = task.sourceHost ?? task.kind.badgeLabel
        }
        return [origin, task.totalBytes?.byteString].compactMap { $0 }.joined(separator: " · ")
    }

    /// The large card's trailing stat: time left, else the percent, else what it is doing.
    static func largeTrailing(_ task: DownloadTask) -> String {
        switch task.status {
        case .verifying: return L10n.t("Verifying…")
        case .downloading:
            if let eta = task.estimatedTimeRemaining, eta > 0 {
                return L10n.t("%@ left", DownloadTask.etaString(eta))
            }
            return L10n.t("%d%%", task.percentComplete)
        default: return task.statusCompactText()
        }
    }

    /// The compact card's line under the name, and its colour.
    static func compactMeta(_ task: DownloadTask, speed: SpeedSample, queueRank: Int?,
                            locale: Locale = DisplayFormat.appLocale) -> (text: String, tone: Tone) {
        let size = task.totalBytes?.byteString
        if task.isFileMissing {
            let folder = (task.saveDirectory as NSString).abbreviatingWithTildeInPath
            return (L10n.t("File missing · was in %@", folder), .warn)
        }
        switch task.status {
        case .queued:
            return (join(task.kind.badgeLabel, size, task.statusCompactText(queueRank: queueRank)), .plain)
        case .requestingMetadata:
            return (task.statusDetailText, .info)
        case .paused:
            return (join(task.statusDetailText, size), .plain)
        case .failed(let error):
            return (error.message, .bad)
        case .seeding:
            let ratio: String
            if let limit = task.seedRatioLimit, limit > 0 {
                ratio = L10n.t("Seeding %1$.2f× of %2$.2f×", task.shareRatio, limit)
            } else {
                ratio = L10n.t("Seeding %.2f×", task.shareRatio)
            }
            return (speed.up >= 1 ? join(ratio, "↑ " + speed.up.speedString) : ratio, .upload)
        case .completed:
            let finished = DisplayFormat.compactDateTime(task.completedAt ?? task.addedAt, locale: locale)
            return (join(task.kind.badgeLabel, size, finished), .plain)
        case .downloading, .verifying:
            return (join(speed.down >= 1 ? "↓ " + speed.down.speedString : nil, task.statusCompactText()), .accent)
        }
    }

    private static func join(_ parts: String?...) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
