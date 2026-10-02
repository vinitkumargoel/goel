import Foundation
import SwiftUI
import GoelCore

/// One label per protocol, wherever a kind badge is drawn.
extension DownloadKind {
    var badgeLabel: String {
        switch self {
        case .torrent: return "BT"
        case .hls: return "HLS"
        case .http: return "HTTP"
        case .ftp: return "FTP"
        case .sftp: return "SFTP"
        }
    }
}

extension DownloadTask {

    var fileType: FileType {
        if case .magnet = source, totalBytes == nil { return .magnet }
        return FileType.classify(fileName: name, isTorrent: kind == .torrent)
    }

    var isMediaFile: Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["mp4", "mkv", "avi", "mov", "webm", "flv", "ts", "m4v", "mpg",
                "mpeg", "wmv", "3gp", "mp3", "m4a", "aac", "flac", "wav", "ogg",
                "opus", "wma"].contains(ext)
    }

    var kindBadge: String { kind.badgeLabel }

    /// Finished, but the file is no longer where the row says (moved, deleted, disk gone).
    var isFileMissing: Bool { status == .completed && fileMissing == true }

    var statusDetailText: String {
        switch status {
        case .queued: return L10n.t("Queued")
        case .requestingMetadata: return L10n.t("Requesting info…")
        case .downloading:
            let pct = Int((fractionCompleted * 100).rounded())
            if let eta = estimatedTimeRemaining, eta > 0 {
                return L10n.t("%1$d%% · %2$@ left", pct, Self.etaString(eta))
            }
            return L10n.t("%d%%", pct)
        case .verifying:
            return L10n.t("Verifying…")
        case .paused:
            return L10n.t("Paused · %d%%", Int((fractionCompleted * 100).rounded()))
        case .seeding:
            if let limit = seedRatioLimit, limit > 0 {
                return L10n.t("Seeding · ratio %1$.2f / %2$.1f", shareRatio, limit)
            }
            return L10n.t("Seeding · ratio %.2f", shareRatio)
        case .completed:
            return isFileMissing ? L10n.t("File missing") : L10n.t("Completed")

        case .failed(let error):
            return error.message
        }
    }

    /// The list's 150 pt status column. The long forms above truncated there ("Seeding · ratio 2…"),
    /// and the percent repeated what the row's bar already draws, so this keeps only what the bar
    /// cannot say. ``statusDetailText`` stays the tooltip and the menu bar's line.
    /// - Parameter queueRank: The row's place in the queue ("#3"), shown while it waits.
    func statusCompactText(queueRank: Int? = nil) -> String {
        switch status {
        case .queued:
            return queueRank.map { L10n.t("Queued · #%d", $0) } ?? L10n.t("Queued")
        case .downloading:
            if let eta = estimatedTimeRemaining, eta > 0 {
                return L10n.t("%@ left", Self.etaString(eta))
            }
            return L10n.t("%d%%", Int((fractionCompleted * 100).rounded()))
        case .seeding:
            return L10n.t("Seeding %.2f×", shareRatio)
        default:
            return statusDetailText
        }
    }

    /// Whether Overview carries the old Progress tab's section: a torrent's piece map while it is
    /// unfinished, or live segments. A single-connection download would only repeat the ring.
    var showsProgressDetail: Bool {
        if kind == .torrent { return status != .completed && status != .seeding }
        return !(connections ?? []).isEmpty
    }

    /// The compact list has no Speed column, so the rate leads the status: "↓ 7.7 MB/s · 1m left".
    func statusFoldedText(speed: SpeedSample, queueRank: Int? = nil) -> String {
        let compact = statusCompactText(queueRank: queueRank)
        switch status {
        case .downloading where speed.down >= 1:
            return L10n.t("%1$@ · %2$@", "↓ " + speed.down.speedString, compact)
        case .seeding where speed.up >= 1:
            return L10n.t("%1$@ · %2$@", "↑ " + speed.up.speedString, compact)
        default:
            return compact
        }
    }

    /// The compact list's line under the name, standing in for the Size column: "2.2 GB · 78%".
    /// A finished row needs no percent; an unknown size keeps only the percent.
    var compactSizeLine: String {
        let percent = L10n.t("%d%%", percentComplete)
        guard let total = totalBytes, total > 0 else { return status == .completed ? "" : percent }
        if status == .completed || status == .seeding { return total.byteString }
        return L10n.t("%1$@ · %2$@", total.byteString, percent)
    }

    /// How far a seeding torrent is toward its ratio target, for the status column's micro-bar;
    /// nil when it seeds without a target, so no bar pretends there is one.
    var seedTargetProgress: Double? {
        guard status == .seeding else { return nil }
        return seedRatioProgress
    }

    /// "1h 30m", "4m 5s", "12s" — abbreviated in the app's language ("1 Std., 30 Min." in German),
    /// two units at most, so the GUI and the CLI agree instead of the GUI saying "1.5h".
    static func etaString(_ seconds: TimeInterval, locale: Locale = DisplayFormat.appLocale) -> String {
        DisplayFormat.duration(seconds, locale: locale)
    }

    /// "Today at 14:03", "Yesterday at 2:03 PM", "12 Mar 2026 at 14:03" — relative words, date
    /// order and the 12/24-hour clock all follow the locale instead of a fixed English pattern.
    var addedString: String { Self.addedString(for: addedAt) }

    /// The list's narrow column: "Yesterday at 11:45 PM" doesn't fit, so it is "Yest 23:45" or
    /// "12 Mar". The detail panel and the tooltip keep the full form.
    var addedColumnString: String { DisplayFormat.compactDateTime(addedAt, locale: DisplayFormat.appLocale) }

    static func addedString(for date: Date, locale: Locale = DisplayFormat.appLocale) -> String {
        DisplayFormat.relativeDateTime(date, locale: locale)
    }

    var magnetInfoHash: String? {
        guard case .magnet(let m) = source else { return nil }
        guard let range = m.range(of: #"btih:([a-zA-Z0-9]+)"#, options: .regularExpression) else { return nil }
        return String(m[range]).replacingOccurrences(of: "btih:", with: "")
    }

    var displayInfoHash: String? { infoHash ?? magnetInfoHash }

    var sourceLocator: String { source.locator }
}

extension DownloadKind {
    var symbolName: String {
        switch self {
        case .http: return "arrow.down.circle"
        case .torrent: return "point.3.connected.trianglepath.dotted"
        case .hls: return "play.rectangle"
        case .ftp: return "server.rack"
        case .sftp: return "lock.rectangle.on.rectangle"
        }
    }
}

/// The list's one Speed column: ↓ on top, ↑ under it only while something is uploading (or a
/// torrent is downloading, where the upload rate is part of the story). Idle is blank, not "—".
struct SpeedCellText: Equatable {
    let down: String?
    let up: String?

    var isEmpty: Bool { down == nil && up == nil }

    init(speed: SpeedSample, isTorrent: Bool) {
        let downloading = speed.down >= 1
        let uploading = speed.up >= 1
        down = downloading ? "↓ " + speed.down.speedString : nil
        if uploading {
            up = "↑ " + speed.up.speedString
        } else if isTorrent && downloading {
            // Not `byteString`: the formatter spells zero as "Zero KB".
            up = L10n.t("↑ 0 B/s")
        } else {
            up = nil
        }
    }
}

extension DownloadTask {

    /// The name a compact row shows. A magnet still fetching its metadata has no real name yet —
    /// only the generic placeholder or, from some sources, the raw `magnet:?xt=…` URI — so it
    /// reads "Fetching metadata · 5c1a9d3e" (the start of its info-hash) instead.
    var compactDisplayName: String {
        guard case .magnet = source, totalBytes == nil else { return name }
        return Self.pendingMagnetTitle(name: name, infoHash: displayInfoHash) ?? name
    }

    /// nil when `name` is already a real name (a magnet's `dn=`) worth showing as-is.
    static func pendingMagnetTitle(name: String, infoHash: String?) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let isPlaceholder = trimmed.isEmpty
            || trimmed == "Magnet download"
            || trimmed.lowercased().hasPrefix("magnet:")
        guard isPlaceholder else { return nil }
        guard let hash = infoHash?.trimmingCharacters(in: .whitespacesAndNewlines), !hash.isEmpty else {
            return L10n.t("Fetching metadata")
        }
        return L10n.t("Fetching metadata · %@", String(hash.prefix(8)).lowercased())
    }
}
