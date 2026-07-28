import SwiftUI
import AppKit
import GoelCore

enum A11y {

    private static let byteUnitWords = ["bytes", "kilobytes", "megabytes", "gigabytes", "terabytes"]

    static func bytes(_ value: Int64?) -> String {
        guard let value, value > 0 else { return "unknown size" }
        let amount = Double(value)
        let exp = min(Int(log(amount) / log(1024)), byteUnitWords.count - 1)
        let scaled = amount / pow(1024, Double(exp))
        let number = exp == 0 ? String(format: "%.0f", scaled) : String(format: "%.1f", scaled)
        return "\(number) \(byteUnitWords[exp])"
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "idle" }
        return bytes(Int64(bytesPerSecond)) + " per second"
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((max(0, min(1, fraction)) * 100).rounded())) percent"
    }

    static func eta(_ seconds: TimeInterval?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        if seconds >= 3600 {
            let hours = seconds / 3600
            return "about \(String(format: "%.1f", hours)) hours remaining"
        }
        if seconds >= 60 {
            let minutes = Int((seconds / 60).rounded())
            return "about \(minutes) minute\(minutes == 1 ? "" : "s") remaining"
        }
        let secs = Int(seconds.rounded())
        return "about \(secs) second\(secs == 1 ? "" : "s") remaining"
    }

    static func sentence(_ parts: String?...) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

extension DownloadTask {

    var accessibilityKindName: String {
        switch kind {
        case .torrent: return "BitTorrent"
        case .hls: return "HLS stream"
        case .http: return "HTTP"
        case .ftp: return "FTP"
        case .sftp: return "SFTP"
        }
    }

    var accessibilityStatusName: String {
        switch status {
        case .queued: return "Queued"
        case .requestingMetadata: return "Requesting information"
        case .downloading: return "Downloading"
        case .verifying: return "Verifying"
        case .paused: return "Paused"
        case .seeding: return "Seeding"
        case .completed: return "Completed"
        case .failed(let error): return "Failed, \(error.message)"
        }
    }

    /// Speed is excluded: sampled twice a second, it would make VoiceOver re-announce the row continuously.
    var accessibilityProgressValue: String {
        A11y.sentence(
            A11y.percent(fractionCompleted),
            "\(A11y.bytes(bytesDownloaded)) of \(A11y.bytes(totalBytes))",
            A11y.eta(estimatedTimeRemaining))
    }

    var accessibilityRowLabel: String {
        A11y.sentence(
            name,
            accessibilityKindName,
            accessibilityStatusName,
            A11y.percent(fractionCompleted),
            A11y.bytes(totalBytes),
            A11y.eta(estimatedTimeRemaining))
    }

    var accessibilityStateActionName: String {
        switch status {
        case .completed: return "Show in Finder"
        case .failed: return "Retry"
        case .paused, .queued: return "Resume"
        default: return "Pause"
        }
    }
}

@MainActor
enum A11yAnnouncer {

    static func announce(_ message: String) {
        guard !message.isEmpty else { return }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }
}

extension SidebarFilter {
    var accessibilityName: String {
        switch self {
        case .all: return "All files"
        case .active: return "Active"
        case .paused: return "Paused"
        case .completed: return "Completed"
        case .seeding: return "Seeding"
        case .type(let fileType): return fileType.accessibilityName
        }
    }
}

extension FileType {
    var accessibilityName: String {
        switch self {
        case .iso: return "Disc images"
        case .video: return "Video"
        case .archive: return "Archives"
        case .app: return "Apps"
        case .magnet: return "Magnet links"
        case .doc: return "Documents"
        }
    }
}

extension SortKey {
    var accessibilityName: String {
        self == .index ? "Row number" : rawValue
    }
}

extension ServerReachability {
    var accessibilityName: String {
        switch self {
        case .unknown: return "Checking"
        case .online: return "Online"
        case .offline: return "Offline"
        }
    }
}

extension View {

    func a11yButton(_ label: String, hint: String? = nil) -> some View {
        accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(hint ?? "")
    }

    func a11yGroup(label: String, value: String? = nil, hint: String? = nil) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value ?? "")
            .accessibilityHint(hint ?? "")
    }

    func a11yDecorative() -> some View {
        accessibilityHidden(true)
    }
}

private struct ScaledSystemFont: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var factor: CGFloat = 100

    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    let monospacedDigit: Bool

    func body(content: Content) -> some View {
        let scaled = size * factor / 100
        let font = Font.system(size: scaled, weight: weight, design: design)
        return content.font(monospacedDigit ? font.monospacedDigit() : font)
    }
}

extension View {
    func scaledFont(size: CGFloat,
                    weight: Font.Weight = .regular,
                    design: Font.Design = .default,
                    monospacedDigit: Bool = false) -> some View {
        modifier(ScaledSystemFont(size: size, weight: weight,
                                  design: design, monospacedDigit: monospacedDigit))
    }
}
