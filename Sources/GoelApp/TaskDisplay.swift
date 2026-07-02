import Foundation
import SwiftUI
import GoelCore

/// View-layer presentation helpers over the frozen `DownloadTask` model. These
/// are pure, derived, and never mutate the core.
extension DownloadTask {

    /// The visual file-type category, inferred from the name (and source kind).
    var fileType: FileType {
        let lower = name.lowercased()
        if case .magnet = source, totalBytes == nil { return .magnet }
        if lower.contains(".iso") { return .iso }
        if lower.range(of: #"\.(mkv|mp4|avi|mov|webm)"#, options: .regularExpression) != nil { return .video }
        if lower.range(of: #"\.(zip|gz|tar|7z|rar|dmg|bz2|xz)"#, options: .regularExpression) != nil { return .archive }
        if lower.range(of: #"\.(app|xip|pkg|exe|deb|msi)"#, options: .regularExpression) != nil { return .app }
        // A torrent without a recognised extension still leans "video" in the demo
        // payload (a season pack), which is what the mock engine synthesizes.
        if kind == .torrent { return .video }
        return .doc
    }

    /// Whether the finished file looks like audio/video ffmpeg can convert or
    /// extract audio from. Drives the ffmpeg context-menu items.
    var isMediaFile: Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["mp4", "mkv", "avi", "mov", "webm", "flv", "ts", "m4v", "mpg",
                "mpeg", "wmv", "3gp", "mp3", "m4a", "aac", "flac", "wav", "ogg",
                "opus", "wma"].contains(ext)
    }

    /// "HTTP" / "BT" / "HLS" / "FTP" / "SFTP" badge text.
    var kindBadge: String {
        switch kind {
        case .torrent: return "BT"
        case .hls: return "HLS"
        case .http: return "HTTP"
        case .ftp: return "FTP"
        case .sftp: return "SFTP"
        }
    }

    var kindBadgeColor: Color {
        switch kind {
        case .torrent: return Theme.purple
        case .hls: return Theme.orange
        case .http: return Theme.teal
        case .ftp: return Theme.green
        case .sftp: return Theme.indigo
        }
    }

    /// The colored status dot tint.
    var statusColor: Color {
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

    /// The progress-bar tint, matching the mockup's per-state coloring.
    var progressTint: Color {
        switch status {
        case .seeding, .completed: return Theme.green
        case .paused, .queued: return .secondary
        case .failed: return Theme.red
        default: return Theme.accent
        }
    }

    /// A compact, human description of the row's current state.
    var statusDetailText: String {
        switch status {
        case .queued: return "Queued"
        case .requestingMetadata: return "Requesting info…"
        case .downloading:
            let pct = Int((fractionCompleted * 100).rounded())
            if let eta = estimatedTimeRemaining, eta > 0 {
                return "\(pct)% · \(Self.etaString(eta)) left"
            }
            return "\(pct)%"
        case .verifying:
            return "Verifying…"
        case .paused:
            return "Paused · \(Int((fractionCompleted * 100).rounded()))%"
        case .seeding:
            if let limit = seedRatioLimit, limit > 0 {
                return String(format: "Seeding · ratio %.2f / %.1f", shareRatio, limit)
            }
            return String(format: "Seeding · ratio %.2f", shareRatio)
        case .completed:
            return "Completed"
        case .failed(let error):
            return error.message
        }
    }

    static func etaString(_ seconds: TimeInterval) -> String {
        if seconds >= 3600 { return String(format: "%.1fh", seconds / 3600) }
        if seconds >= 60 { return String(format: "%.0fm", seconds / 60) }
        return String(format: "%.0fs", seconds)
    }

    // Cached formatters — `DateFormatter()` init is expensive (loads locale /
    // calendar / timezone) and `addedString` is read for every visible row.
    private static let todayFormatter = Self.formatter("'Today' HH:mm")
    private static let yesterdayFormatter = Self.formatter("'Yesterday' HH:mm")
    private static let dateFormatter = Self.formatter("dd MMM HH:mm")

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.dateFormat = format
        return f
    }

    var addedString: String {
        let cal = Calendar.current
        if cal.isDateInToday(addedAt) { return Self.todayFormatter.string(from: addedAt) }
        if cal.isDateInYesterday(addedAt) { return Self.yesterdayFormatter.string(from: addedAt) }
        return Self.dateFormatter.string(from: addedAt)
    }

    /// The info-hash parsed from a magnet link, used as a fallback before the
    /// engine resolves the real one (which also covers `.torrent` files). Prefer
    /// the model's stored ``DownloadTask/infoHash``; fall back to this.
    var magnetInfoHash: String? {
        guard case .magnet(let m) = source else { return nil }
        guard let range = m.range(of: #"btih:([a-zA-Z0-9]+)"#, options: .regularExpression) else { return nil }
        return String(m[range]).replacingOccurrences(of: "btih:", with: "")
    }

    /// The best info-hash to display: the engine-resolved one (works for
    /// `.torrent` files too), else the magnet link's.
    var displayInfoHash: String? { infoHash ?? magnetInfoHash }

    /// The canonical source string for display / copy.
    var sourceLocator: String { source.locator }
}

extension DownloadKind {
    /// The SF Symbol representing this transport in preview and history rows.
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
