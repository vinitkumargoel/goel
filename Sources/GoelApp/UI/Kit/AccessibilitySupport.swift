import SwiftUI
import AppKit
import GoelCore

enum A11y {

    /// Computed, not `static let`: a cached array would keep the language it was first built in.
    private static var byteUnitWords: [String] {
        [L10n.t("bytes"), L10n.t("kilobytes"), L10n.t("megabytes"),
         L10n.t("gigabytes"), L10n.t("terabytes")]
    }

    static func bytes(_ value: Int64?) -> String {
        guard let value, value > 0 else { return L10n.t("unknown size") }
        let words = byteUnitWords
        let amount = Double(value)
        let exp = min(Int(log(amount) / log(1024)), words.count - 1)
        let scaled = amount / pow(1024, Double(exp))
        let number = exp == 0 ? String(format: "%.0f", scaled) : String(format: "%.1f", scaled)
        return L10n.t("%1$@ %2$@", number, words[exp])
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return L10n.t("idle") }
        return L10n.t("%@ per second", bytes(Int64(bytesPerSecond)))
    }

    static func percent(_ fraction: Double) -> String {
        L10n.t("%d percent", Int((max(0, min(1, fraction)) * 100).rounded()))
    }

    static func eta(_ seconds: TimeInterval?) -> String? {
        guard let seconds, seconds > 0 else { return nil }
        if seconds >= 3600 {
            return L10n.t("about %.1f hours remaining", seconds / 3600)
        }
        if seconds >= 60 {
            let minutes = Int((seconds / 60).rounded())
            return minutes == 1 ? L10n.t("about %d minute remaining", minutes)
                                : L10n.t("about %d minutes remaining", minutes)
        }
        let secs = Int(seconds.rounded())
        return secs == 1 ? L10n.t("about %d second remaining", secs)
                         : L10n.t("about %d seconds remaining", secs)
    }

    static func sentence(_ parts: String?...) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

extension DownloadKind {

    var accessibilityName: String {
        switch self {
        case .torrent: return "BitTorrent"
        case .hls: return L10n.t("HLS stream")
        case .http: return "HTTP"
        case .ftp: return "FTP"
        case .sftp: return "SFTP"
        }
    }
}

extension DownloadTask {

    var accessibilityKindName: String { kind.accessibilityName }

    var accessibilityStatusName: String {
        switch status {
        case .queued: return L10n.t("Queued")
        case .requestingMetadata: return L10n.t("Requesting information")
        case .downloading: return L10n.t("Downloading")
        case .verifying: return L10n.t("Verifying")
        case .paused: return L10n.t("Paused")
        case .seeding: return L10n.t("Seeding")
        case .completed: return L10n.t("Completed")
        case .failed(let error): return L10n.t("Failed, %@", error.message)
        }
    }

    /// Speed is excluded: sampled twice a second, it would make VoiceOver re-announce the row continuously.
    var accessibilityProgressValue: String {
        A11y.sentence(
            A11y.percent(fractionCompleted),
            L10n.t("%1$@ of %2$@", A11y.bytes(bytesDownloaded), A11y.bytes(totalBytes)),
            A11y.eta(estimatedTimeRemaining))
    }

    /// What a list row is called: identity only (see the row's label). A pending magnet is its
    /// "Fetching metadata" title, never a raw `magnet:?xt=…` URI read out character by character.
    var accessibilityIdentityLabel: String {
        A11y.sentence(compactDisplayName, accessibilityKindName, accessibilityStatusName)
    }

    var accessibilityRowLabel: String {
        A11y.sentence(
            compactDisplayName,
            accessibilityKindName,
            accessibilityStatusName,
            A11y.percent(fractionCompleted),
            A11y.bytes(totalBytes),
            A11y.eta(estimatedTimeRemaining))
    }

    var accessibilityStateActionName: String {
        switch status {
        case .completed: return L10n.t("Show in Finder")
        case .failed: return L10n.t("Retry")
        case .paused, .queued: return L10n.t("Resume")
        default: return L10n.t("Pause")
        }
    }
}

@MainActor
enum A11yAnnouncer {

    static func announce(_ message: String) {
        // No application object under XCTest: nothing to announce through.
        guard !message.isEmpty, let app = NSApp else { return }
        NSAccessibility.post(
            element: app,
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
        case .all: return L10n.t("All downloads")
        case .active: return L10n.t("Active")
        case .paused: return L10n.t("Paused")
        case .completed: return L10n.t("Completed")
        case .seeding: return L10n.t("Seeding")
        case .failed: return L10n.t("Failed")
        case .queued: return L10n.t("Queued")
        case .type(let fileType): return fileType.accessibilityName
        case .tag(let name): return name
        }
    }
}

extension FileType {
    var accessibilityName: String {
        switch self {
        case .iso: return L10n.t("Disc images")
        case .video: return L10n.t("Video")
        case .archive: return L10n.t("Archives")
        case .app: return L10n.t("Apps")
        case .magnet: return L10n.t("Magnet links")
        case .doc: return L10n.t("Documents")
        case .audio: return L10n.t("Audio")
        case .image: return L10n.t("Images")
        case .other: return L10n.t("Other")
        }
    }
}

extension SortKey {
    /// Every name is a literal `L10n.t` key so the extractor sees it; `rawValue` is a storage id.
    var title: String {
        switch self {
        case .index: return L10n.t("Queue order")
        case .name: return L10n.t("Name")
        case .size: return L10n.t("Size")
        case .status: return L10n.t("Status")
        case .added: return L10n.t("Added")
        case .downloadSpeed: return L10n.t("Download speed")
        case .uploadSpeed: return L10n.t("Upload speed")
        }
    }

    /// The compact column header; "↓ Speed" and "#" are keys too, so a translation can change them.
    var columnTitle: String {
        switch self {
        case .index: return L10n.t("#")
        case .downloadSpeed: return L10n.t("↓ Speed")
        case .uploadSpeed: return L10n.t("↑ Speed")
        default: return title
        }
    }

    var accessibilityName: String { title }
}

extension DetailTab {
    var title: String {
        switch self {
        case .overview: return L10n.t("Overview")
        case .files: return L10n.t("Files")
        case .network: return L10n.t("Network")
        }
    }
}

extension FilePriority {
    var title: String {
        switch self {
        case .skip: return L10n.t("Skip")
        case .low: return L10n.t("Low")
        case .normal: return L10n.t("Normal")
        case .high: return L10n.t("High")
        }
    }
}

extension ServerReachability {
    var accessibilityName: String {
        switch self {
        case .unknown: return L10n.t("Checking")
        case .online: return L10n.t("Online")
        case .offline: return L10n.t("Offline")
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

/// Tooltips that name their shortcut, e.g. "Toggle detail panel (⌘I)". The key glyphs read the
/// same in every language, so only the text half goes through `L10n.t`.
enum ShortcutHint {
    static func help(_ text: String, _ keys: String) -> String {
        "\(text) (\(keys))"
    }
}
