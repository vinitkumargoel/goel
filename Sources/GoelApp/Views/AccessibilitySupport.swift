import SwiftUI
import AppKit
import GoelCore

// ============================================================================
// Spoken-text helpers for VoiceOver.
//
// The visible UI is deliberately terse — "4.2 MB/s", "62%", "~6m" — because it
// has to fit a 84pt column. A screen reader reads those literally: "four point
// two M B slash S", "tilde six m". Unit abbreviations and symbols are for the
// eye, not the ear.
//
// So every accessibility string in the app is built from these helpers rather
// than reusing `byteString` / `speedString` / `etaText`. They expand units into
// words and drop the punctuation VoiceOver has no good pronunciation for. The
// visible label never changes; only what is spoken does.
//
// Nothing here reaches the network, reads user data, or is persisted — it is
// pure text derivation over values the view already has on screen.
// ============================================================================

/// Builders for the spoken half of the interface.
enum A11y {

    /// The unit words, ordered to match `byteString`'s 1024-based ladder.
    private static let byteUnitWords = ["bytes", "kilobytes", "megabytes", "gigabytes", "terabytes"]

    /// "4.2 megabytes". Returns "unknown size" for a missing or zero total, which
    /// is what the visible "—" actually means.
    static func bytes(_ value: Int64?) -> String {
        guard let value, value > 0 else { return "unknown size" }
        let amount = Double(value)
        let exp = min(Int(log(amount) / log(1024)), byteUnitWords.count - 1)
        let scaled = amount / pow(1024, Double(exp))
        // Whole bytes never need a decimal; everything else reads better with one
        // than with two ("four point two" beats "four point one nine").
        let number = exp == 0 ? String(format: "%.0f", scaled) : String(format: "%.1f", scaled)
        return "\(number) \(byteUnitWords[exp])"
    }

    /// "4.2 megabytes per second", or "idle" at rest — "—" is silent to VoiceOver.
    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "idle" }
        return bytes(Int64(bytesPerSecond)) + " per second"
    }

    /// "62 percent" from a 0…1 fraction.
    static func percent(_ fraction: Double) -> String {
        "\(Int((max(0, min(1, fraction)) * 100).rounded())) percent"
    }

    /// "about 6 minutes remaining" — the spoken form of the "~6m" chip. `nil`
    /// when there is no estimate, so callers can omit the clause entirely rather
    /// than speak a placeholder.
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

    /// Join non-empty clauses with commas, so an omitted clause leaves no
    /// stranded punctuation for VoiceOver to pause on.
    static func sentence(_ parts: String?...) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

// MARK: - Task descriptions

extension DownloadTask {

    /// What the transport is, spelled out — the ear can't read a "BT" badge.
    /// Matches ``kindBadge`` one for one.
    var accessibilityKindName: String {
        switch kind {
        case .torrent: return "BitTorrent"
        case .hls: return "HLS stream"
        case .http: return "HTTP"
        case .ftp: return "FTP"
        case .sftp: return "SFTP"
        }
    }

    /// The status as a spoken phrase. Deliberately *not* ``statusDetailText``:
    /// that packs percent, ETA and ratio into the same string with "·"
    /// separators, which VoiceOver reads as "middle dot". Here the status is just
    /// the state; the numbers travel in ``accessibilityProgressValue`` so a
    /// screen reader can re-read the value alone as it changes.
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

    /// The spoken value of this download's progress:
    /// "62 percent, 4.2 megabytes of 6.8 gigabytes, about 6 minutes remaining".
    ///
    /// Speed is *not* included: it is sampled twice a second and would make
    /// VoiceOver re-announce the row continuously. Call sites that own a live
    /// speed readout label that readout separately.
    var accessibilityProgressValue: String {
        A11y.sentence(
            A11y.percent(fractionCompleted),
            "\(A11y.bytes(bytesDownloaded)) of \(A11y.bytes(totalBytes))",
            A11y.eta(estimatedTimeRemaining))
    }

    /// The whole row as one utterance, so a download reads as a single item
    /// instead of eight fragments (index, name, badge, bar, size, dot, date,
    /// two speeds). Used with `.accessibilityElement(children: .ignore)`.
    var accessibilityRowLabel: String {
        A11y.sentence(
            name,
            accessibilityKindName,
            accessibilityStatusName,
            A11y.percent(fractionCompleted),
            A11y.bytes(totalBytes),
            A11y.eta(estimatedTimeRemaining))
    }

    /// The verb the row's state button performs right now — the same branch
    /// ``StateButton`` uses for its symbol, so label and behaviour can't drift.
    var accessibilityStateActionName: String {
        switch status {
        case .completed: return "Show in Finder"
        case .failed: return "Retry"
        case .paused, .queued: return "Resume"
        default: return "Pause"
        }
    }
}

// MARK: - Announcements

/// Speaks a transient message that has no lasting place in the interface.
///
/// The app reports several things purely as a toast or a banner that fades: a
/// copied link, a finished conversion, an ffmpeg refusal. Those appear and
/// disappear without ever taking focus, so a screen-reader user is simply never
/// told — the feedback for an action they just took goes missing.
///
/// This posts a local `announcementRequested` notification to the accessibility
/// system on this Mac. It transmits nothing, stores nothing, and does nothing at
/// all unless assistive technology is running.
@MainActor
enum A11yAnnouncer {

    /// Speak `message` at high priority, interrupting lower-priority speech —
    /// these are direct responses to a user action, so a queued announcement
    /// that lands ten seconds later would be worse than none.
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

// MARK: - Filter and sort names

extension SidebarFilter {
    /// The filter as a spoken phrase. `SidebarFilter` has no display string of
    /// its own — call sites hard-code the label next to each icon — so the
    /// toolbar's Filter menu had nothing to announce as its current value.
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
    /// The type category in words, matching the sidebar's visible labels.
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
    /// The sort column in words. `rawValue` is the *visible* heading, and for
    /// ``SortKey/index`` that is the bare symbol "#".
    var accessibilityName: String {
        self == .index ? "Row number" : rawValue
    }
}

extension ServerReachability {
    /// Reachability in words. The sidebar shows this state *only* as a 7pt
    /// coloured dot, which is both invisible to a screen reader and a
    /// colour-alone signal for everyone else; the tooltip is pointer-only.
    var accessibilityName: String {
        switch self {
        case .unknown: return "Checking"
        case .online: return "Online"
        case .offline: return "Offline"
        }
    }
}

// MARK: - View conveniences

extension View {

    /// Label an icon-only control and state that it is a button, in one call.
    /// Used for the many `Image(systemName:)`-in-a-`Button` controls where the
    /// glyph carries the entire meaning.
    func a11yButton(_ label: String, hint: String? = nil) -> some View {
        accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(hint ?? "")
    }

    /// Collapse a composed group into one VoiceOver element with a single label
    /// and (optionally) a spoken value — the fix for rows that would otherwise be
    /// read as a stream of disconnected fragments.
    func a11yGroup(label: String, value: String? = nil, hint: String? = nil) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value ?? "")
            .accessibilityHint(hint ?? "")
    }

    /// Mark a purely decorative graphic (gradient tiles, dashed drop outlines,
    /// legend swatches) as invisible to assistive technology. The meaning it
    /// carries visually is always also stated in a nearby label.
    func a11yDecorative() -> some View {
        accessibilityHidden(true)
    }
}

// MARK: - Dynamic Type

/// A system font whose point size tracks the macOS Accessibility → Display →
/// **Text size** setting, while rendering at the design's exact size when that
/// setting is at its default.
///
/// `Font.system(size:)` is a fixed measurement and ignores the setting entirely,
/// which is why the app's terse 10.5–13.5pt type was previously unresizable. The
/// obvious fix — swapping every call for a semantic style like `.body` — would
/// redraw the whole visual language, because the design's sizes deliberately sit
/// between the system styles. `@ScaledMetric` keeps the design and gains the
/// scaling: the metric is declared as a percentage that SwiftUI multiplies by
/// the user's text-size factor, and the point size is derived from it.
private struct ScaledSystemFont: ViewModifier {
    /// Declared relative to `.body` so it moves with the same factor the system
    /// applies to ordinary body copy.
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
    /// Drop-in replacement for `.font(.system(size:weight:design:))` that honours
    /// the system text-size setting. Use on body copy the user has to *read*
    /// (names, statuses, values); leave fixed sizes on glyph-only chrome where a
    /// larger symbol would break the layout without helping legibility.
    func scaledFont(size: CGFloat,
                    weight: Font.Weight = .regular,
                    design: Font.Design = .default,
                    monospacedDigit: Bool = false) -> some View {
        modifier(ScaledSystemFont(size: size, weight: weight,
                                  design: design, monospacedDigit: monospacedDigit))
    }
}
