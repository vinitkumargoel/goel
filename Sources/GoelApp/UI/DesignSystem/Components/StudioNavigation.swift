import SwiftUI
import GoelCore

/// One item of the icon rail (`.ri`). Collapsed it is a 44 pt glyph tile with an optional badge
/// and a tooltip; expanded (`.rail.wide`) it shows the title and a mono count.
///
///     StudioRailItem(symbol: "rectangle.3.group", title: "Downloads", badge: 4,
///                    isSelected: true, shortcut: "⌘1") { … }
struct StudioRailItem: View {
    enum BadgeTone: Sendable { case accent, bad }

    let symbol: String
    let title: String
    var badge: Int?
    var badgeTone: BadgeTone = .accent
    /// The expanded rail's trailing count (`.rail.wide .ri .n`).
    var count: Int?
    var isSelected = false
    var isExpanded = false
    var shortcut: String?
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Studio.Radius.tile, style: .continuous)
        Button(action: action) {
            HStack(spacing: Studio.Space.sm) {
                Image(systemName: symbol)
                    .font(StudioFonts.font(.ui, size: 17, weight: 600))
                    .frame(width: 20, height: 20)
                if isExpanded {
                    Text(title)
                        .studioFont(.bodyStrong)
                        .lineLimit(1)
                    Spacer(minLength: Studio.Space.s)
                    if let count {
                        Text(verbatim: "\(count)")
                            .studioFont(.monoSmall)
                            .foregroundStyle(Studio.Palette.ink3)
                    }
                }
            }
            .foregroundStyle(isSelected ? Studio.Palette.accent : hovered ? Studio.Palette.ink : Studio.Palette.ink2)
            .padding(.horizontal, isExpanded ? Studio.Space.sm : 0)
            .frame(width: isExpanded ? nil : 44, height: isExpanded ? 38 : 44)
            .frame(maxWidth: isExpanded ? .infinity : nil, alignment: .leading)
            .background {
                if isSelected {
                    shape.fill(Studio.Palette.card).studioElevation(.card)
                } else if hovered {
                    shape.fill(Studio.Palette.segment)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let badge, badge > 0, !isExpanded {
                    StudioRailBadge(value: badge, tone: badgeTone)
                        .offset(x: -4, y: 4)
                }
            }
            .studioButtonFocusRing(shape: shape)
            .contentShape(shape)
        }
        .buttonStyle(.studioPlain)
        .onHover { hovered = $0 }
        .help(shortcut.map { ShortcutHint.help(title, $0) } ?? title)
        .accessibilityLabel(title)
        .accessibilityValue(badge.map { L10n.t("%d items", $0) } ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The rail's count bubble (`.ri .dot`), ringed in the rail colour so it reads over the tile.
struct StudioRailBadge: View {
    let value: Int
    var tone: StudioRailItem.BadgeTone = .accent

    var body: some View {
        Text(verbatim: value > 99 ? "99+" : "\(value)")
            .font(StudioFonts.font(.ui, size: 9.5, weight: 700, tabularNumbers: true))
            .foregroundStyle(Studio.Palette.onAccent)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .background(Capsule().fill(tone == .bad ? Studio.Palette.bad : Studio.Palette.accent))
            .overlay(Capsule().strokeBorder(Studio.Palette.rail, lineWidth: 2))
            .fixedSize()
            .accessibilityHidden(true)
    }
}

/// The short rule between rail groups (`.rsep`).
struct StudioRailSeparator: View {
    var isExpanded = false

    var body: some View {
        Rectangle()
            .fill(Studio.Palette.hairlineStrong)
            .frame(width: isExpanded ? nil : 28, height: 1)
            .frame(maxWidth: isExpanded ? .infinity : nil)
            .padding(.vertical, Studio.Space.xs)
            .accessibilityHidden(true)
    }
}

/// A board lane's header (`.lane-h`): display title, count bubble, trailing note.
///
///     StudioLaneHeader(title: "Downloading", count: 4, detail: "↓ 43 MB/s", detailIsMono: true)
///     StudioLaneHeader(title: "Needs you", count: 2, actionTitle: "Retry All") { retryAll() }
struct StudioLaneHeader: View {
    let title: String
    var count: Int?
    var detail: String?
    var detailIsMono = false
    /// An optional trailing button, e.g. "Retry All" on the "Needs you" lane.
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: Studio.Space.s) {
            Text(title)
                .studioFont(.lane)
                .foregroundStyle(Studio.Palette.ink)
                .accessibilityAddTraits(.isHeader)
            if let count {
                Text(verbatim: "\(count)")
                    .studioFont(.monoSmall.weight(600))
                    .foregroundStyle(Studio.Palette.ink2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(Studio.Palette.segment, in: Capsule())
                    .accessibilityLabel(L10n.t("%d items", count))
            }
            Spacer(minLength: Studio.Space.s)
            if let detail {
                Text(detail)
                    .studioFont(detailIsMono ? .monoSmall : .caption)
                    .foregroundStyle(Studio.Palette.ink3)
                    .lineLimit(1)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.studio(.ghost, size: .small))
            }
        }
        .padding(.horizontal, Studio.Space.xxs)
        .padding(.bottom, 2)
        .accessibilityElement(children: actionTitle == nil ? .combine : .contain)
    }
}

/// The Goel° wordmark (`.wm`): display weight with the accent degree sign.
struct StudioWordmark: View {
    var size: CGFloat = 18

    var body: some View {
        HStack(alignment: .top, spacing: 1) {
            Text(verbatim: "Goel")
                .font(StudioFonts.font(.display, size: size, weight: 750))
                .tracking(-size * 0.03)
                .foregroundStyle(Studio.Palette.ink)
            Text(verbatim: "°")
                .font(StudioFonts.font(.display, size: size * 0.8, weight: 750))
                .foregroundStyle(Studio.Palette.accent)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "Goel°"))
    }
}
