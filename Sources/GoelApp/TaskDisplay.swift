import Foundation
import SwiftUI
import GoelCore

/// One label and one colour per protocol, wherever a kind badge is drawn.
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

    var badgeColor: Color {
        switch self {
        case .torrent: return Theme.purple
        case .hls: return Theme.orange
        case .http: return Theme.teal
        case .ftp: return Theme.green
        case .sftp: return Theme.indigo
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

    var kindBadgeColor: Color { kind.badgeColor }

    /// Finished, but the file is no longer where the row says (moved, deleted, disk gone).
    var isFileMissing: Bool { status == .completed && fileMissing == true }

    var statusColor: Color {
        if isFileMissing { return Theme.orange }
        switch status {
        case .downloading: return Theme.accent
        case .verifying: return Theme.orange
        case .requestingMetadata: return Theme.orange
        case .seeding: return Theme.green
        case .completed: return Theme.green
        case .paused: return .secondary
        case .queued: return .secondary
        case .failed: return Theme.red
        }
    }

    var progressTint: Color {
        switch status {
        case .seeding, .completed: return Theme.green
        case .paused, .queued: return .secondary
        case .failed: return Theme.red
        default: return Theme.accent
        }
    }

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
