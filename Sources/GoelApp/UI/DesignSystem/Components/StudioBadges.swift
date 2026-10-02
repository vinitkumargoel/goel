import SwiftUI
import GoelCore

/// The colour family of a pill, note or toast.
enum StudioTone: Sendable {
    case neutral, accent, good, warn, bad, info, upload

    var foreground: Color {
        switch self {
        case .neutral: return Studio.Palette.ink2
        case .accent: return Studio.Palette.accent
        case .good: return Studio.Palette.good
        case .warn: return Studio.Palette.warn
        case .bad: return Studio.Palette.bad
        case .info: return Studio.Palette.info
        case .upload: return Studio.Palette.upload
        }
    }

    var background: Color {
        switch self {
        case .neutral: return Studio.Palette.segment
        case .accent: return Studio.Palette.accentSoft
        case .good: return Studio.Palette.goodSoft
        case .warn: return Studio.Palette.warnSoft
        case .bad: return Studio.Palette.badSoft
        case .info: return Studio.Palette.infoSoft
        case .upload: return Studio.Palette.uploadSoft
        }
    }
}

/// Every state a download row can show. Built from a task with ``init(task:)``, which separates
/// a finished download whose file has gone (`fileMissing`) from a plain `completed`.
enum StudioDownloadState: CaseIterable, Hashable, Sendable {
    case queued, requestingMetadata, downloading, verifying, paused, seeding, completed, failed, fileMissing

    init(task: DownloadTask) {
        if task.isFileMissing { self = .fileMissing; return }
        switch task.status {
        case .queued: self = .queued
        case .requestingMetadata: self = .requestingMetadata
        case .downloading: self = .downloading
        case .verifying: self = .verifying
        case .paused: self = .paused
        case .seeding: self = .seeding
        case .completed: self = .completed
        case .failed: self = .failed
        }
    }

    var title: String {
        switch self {
        case .queued: return L10n.t("Queued")
        case .requestingMetadata: return L10n.t("Fetching metadata")
        case .downloading: return L10n.t("Downloading")
        case .verifying: return L10n.t("Verifying")
        case .paused: return L10n.t("Paused")
        case .seeding: return L10n.t("Seeding")
        case .completed: return L10n.t("Completed")
        case .failed: return L10n.t("Failed")
        case .fileMissing: return L10n.t("File missing")
        }
    }

    var tone: StudioTone {
        switch self {
        case .queued, .paused: return .neutral
        case .requestingMetadata, .verifying: return .info
        case .downloading: return .accent
        case .seeding: return .upload
        case .completed: return .good
        case .failed: return .bad
        case .fileMissing: return .warn
        }
    }

    var symbol: String {
        switch self {
        case .queued: return "clock"
        case .requestingMetadata: return "antenna.radiowaves.left.and.right"
        case .downloading: return "arrow.down"
        case .verifying: return "checkmark.shield"
        case .paused: return "pause"
        case .seeding: return "arrow.up"
        case .completed: return "checkmark"
        case .failed: return "exclamationmark.triangle"
        case .fileMissing: return "questionmark.folder"
        }
    }
}

/// A rounded status pill with a leading dot (`.pill`).
///
///     StudioPill("Matches", tone: .accent)
///     StudioPill("SHA-256 after finish", tone: .neutral, showsDot: false)
struct StudioPill: View {
    let title: String
    var tone: StudioTone = .neutral
    var showsDot = true

    init(_ title: String, tone: StudioTone = .neutral, showsDot: Bool = true) {
        self.title = title
        self.tone = tone
        self.showsDot = showsDot
    }

    var body: some View {
        HStack(spacing: Studio.Space.xs) {
            if showsDot {
                Circle().fill(tone.foreground).frame(width: 6, height: 6)
                    .accessibilityHidden(true)
            }
            Text(title)
                .studioFont(.caption.weight(650))
                .lineLimit(1)
        }
        .foregroundStyle(tone.foreground)
        .padding(.horizontal, 9)
        .frame(minHeight: 22)
        .background(tone.background, in: Capsule())
        // `segment` sits within a few points of `card` and `well` in dark: a hairline keeps a
        // neutral pill visible on either.
        .overlay {
            if tone == .neutral { Capsule().strokeBorder(Studio.Palette.hairline, lineWidth: 1) }
        }
        .fixedSize()
    }
}

/// A download state as a pill: `StudioStatusChip(state: StudioDownloadState(task: task))`.
/// `detail` overrides the label ("Seeding 1.20×") while keeping the state's colour; VoiceOver
/// hears the state's own name either way.
struct StudioStatusChip: View {
    let state: StudioDownloadState
    var detail: String?

    var body: some View {
        StudioPill(detail ?? state.title, tone: state.tone)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(detail.map { "\(state.title), \($0)" } ?? state.title)
    }
}

/// A small mono badge (`.badge`); `glass` lays it over artwork.
struct StudioBadge: View {
    enum Style { case plain, glass, accent }

    let text: String
    var style: Style = .plain

    init(_ text: String, style: Style = .plain) {
        self.text = text
        self.style = style
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Studio.Radius.badge, style: .continuous)
        Text(text)
            .studioFont(.badge)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .foregroundStyle(style == .plain ? Studio.Palette.ink2 : style == .accent ? Studio.Palette.accent : Studio.Palette.ink)
            .background {
                switch style {
                case .plain:
                    shape.fill(Studio.Palette.segment)
                        .overlay(shape.strokeBorder(Studio.Palette.hairline, lineWidth: 1))
                case .accent: shape.fill(Studio.Palette.accentSoft)
                case .glass: shape.fill(.ultraThinMaterial).overlay(shape.fill(Studio.Palette.glass))
                }
            }
            .fixedSize()
    }
}

/// The protocol badge: HTTP, BT, HLS, FTP, SFTP. Labels come from `DownloadKind.badgeLabel` and
/// the spoken name from `DownloadKind.accessibilityName`, the same ones VoiceOver hears elsewhere.
struct StudioKindBadge: View {
    let kind: DownloadKind
    var style: StudioBadge.Style = .plain

    var body: some View {
        StudioBadge(kind.badgeLabel, style: style)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(kind.accessibilityName)
    }
}

/// A coloured tag label with a rounded square swatch (`.tag`).
struct StudioTagLabel: View {
    let name: String
    var color: Color = Studio.Palette.accent

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(name)
                .studioFont(.caption.weight(600))
                .foregroundStyle(Studio.Palette.ink2)
                .lineLimit(1)
        }
    }
}

/// Key caps for a shortcut hint (`.kbd`): `StudioKeyCaps("⌘K")`, or one cap per key with
/// `StudioKeyCaps(keys: ["⇧", "⌘", "T"])`.
struct StudioKeyCaps: View {
    let keys: [String]

    init(_ shortcut: String) {
        keys = [shortcut]
    }

    init(keys: [String]) {
        self.keys = keys
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                Text(key)
                    .studioFont(.keyCap)
                    .foregroundStyle(Studio.Palette.ink2)
                    .padding(.horizontal, 6)
                    .padding(.top, 3)
                    .padding(.bottom, 4)
                    .background {
                        let shape = RoundedRectangle(cornerRadius: Studio.Radius.badge, style: .continuous)
                        ZStack(alignment: .bottom) {
                            shape.fill(Studio.Palette.hairlineStrong)
                            shape.fill(Studio.Palette.card).padding(.bottom, 1)
                        }
                        .overlay(shape.strokeBorder(Studio.Palette.hairlineStrong, lineWidth: 1))
                    }
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.t("Shortcut %@", keys.joined()))
    }
}
