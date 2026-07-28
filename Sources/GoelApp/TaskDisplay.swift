import Foundation
import SwiftUI
import GoelCore

extension DownloadTask {

    var fileType: FileType {
        let lower = name.lowercased()
        if case .magnet = source, totalBytes == nil { return .magnet }
        if lower.contains(".iso") { return .iso }
        if lower.range(of: #"\.(mkv|mp4|avi|mov|webm)"#, options: .regularExpression) != nil { return .video }
        if lower.range(of: #"\.(zip|gz|tar|7z|rar|dmg|bz2|xz)"#, options: .regularExpression) != nil { return .archive }
        if lower.range(of: #"\.(app|xip|pkg|exe|deb|msi)"#, options: .regularExpression) != nil { return .app }
        if kind == .torrent { return .video }
        return .doc
    }

    var isMediaFile: Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["mp4", "mkv", "avi", "mov", "webm", "flv", "ts", "m4v", "mpg",
                "mpeg", "wmv", "3gp", "mp3", "m4a", "aac", "flac", "wav", "ogg",
                "opus", "wma"].contains(ext)
    }

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
