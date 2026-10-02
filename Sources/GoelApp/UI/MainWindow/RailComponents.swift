import SwiftUI
import GoelCore

/// Which long list the collapsed rail opens beside itself.
enum RailFlyout: Hashable, Sendable {
    /// Library, Status and Type filters.
    case filters
    case tags
    case servers

    var title: String {
        switch self {
        case .filters: return L10n.t("Filters")
        case .tags: return L10n.t("Tags")
        case .servers: return L10n.t("Servers")
        }
    }
}

/// One row of the expanded rail or a rail flyout: glyph (or a tag's colour dot), title, count.
/// Selected rows lift onto a card with an accent glyph, like the settings sidebar.
struct RailRow<Trailing: View>: View {
    let title: String
    var symbol: String?
    var dot: Color?
    var count: Int?
    /// A failed count reads red while there is anything in it.
    var isAlert = false
    var isSelected = false
    var help: String?
    var accessibilityValue: String?
    var accessibilityHint: String?
    let action: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Studio.Radius.small, style: .continuous)
        Button(action: action) {
            HStack(spacing: Studio.Space.sm) {
                leading
                    .frame(width: 18)
                    .accessibilityHidden(true)
                Text(title)
                    .studioFont(.bodyStrong)
                    .foregroundStyle(isSelected ? Studio.Palette.ink
                                     : hovered ? Studio.Palette.ink : Studio.Palette.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: Studio.Space.xs)
                trailing()
                countView
            }
            .padding(.horizontal, Studio.Space.sm)
            .frame(minHeight: 32)
            .background {
                if isSelected {
                    shape.fill(Studio.Palette.card).studioElevation(.card)
                } else if hovered {
                    shape.fill(Studio.Palette.segment)
                }
            }
            .studioButtonFocusRing(shape: shape)
            .contentShape(shape)
        }
        .buttonStyle(.studioPlain)
        .onHover { hovered = $0 }
        .help(help ?? title)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue ?? count.map { L10n.t("%d downloads", $0) } ?? "")
        .accessibilityHint(accessibilityHint ?? "")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var leading: some View {
        if let symbol {
            Image(systemName: symbol)
                .studioFont(.ui, size: 13, weight: 600)
                .foregroundStyle(isSelected ? Studio.Palette.accent : Studio.Palette.ink3)
        } else if let dot {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(dot)
                .frame(width: 9, height: 9)
        }
    }

    @ViewBuilder private var countView: some View {
        if let count {
            if isAlert && count > 0 {
                Text(verbatim: "\(count)")
                    .studioFont(.monoSmall.weight(700))
                    .foregroundStyle(Studio.Palette.onAccent)
                    .padding(.horizontal, Studio.Space.xs)
                    .frame(minHeight: 17)
                    .background(Studio.Palette.bad, in: Capsule())
            } else {
                Text(verbatim: "\(count)")
                    .studioFont(.monoSmall)
                    .foregroundStyle(isSelected ? Studio.Palette.ink2 : Studio.Palette.ink3)
            }
        }
    }
}

extension RailRow where Trailing == EmptyView {
    init(title: String, symbol: String? = nil, dot: Color? = nil, count: Int? = nil, isAlert: Bool = false,
         isSelected: Bool = false, help: String? = nil, accessibilityValue: String? = nil,
         accessibilityHint: String? = nil, action: @escaping () -> Void) {
        self.init(title: title, symbol: symbol, dot: dot, count: count, isAlert: isAlert, isSelected: isSelected,
                  help: help, accessibilityValue: accessibilityValue, accessibilityHint: accessibilityHint,
                  action: action, trailing: { EmptyView() })
    }
}

/// A rail group's eyebrow ("STATUS"), optionally with a trailing control (Servers' +).
struct RailSectionHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: Studio.Space.xs) {
            Text(title)
                .studioFont(.eyebrow)
                .foregroundStyle(Studio.Palette.ink3)
                .accessibilityLabel(title)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            accessory()
        }
        .padding(.horizontal, Studio.Space.sm)
        .padding(.top, Studio.Space.ml)
        .padding(.bottom, Studio.Space.xxs)
    }
}

extension RailSectionHeader where Accessory == EmptyView {
    init(_ title: String) {
        self.init(title: title, accessory: { EmptyView() })
    }
}

/// The eight tag colours, in `TagColors` slot order (Blue, Green, Orange, Red, Yellow, Purple,
/// Teal, Indigo), drawn from the Studio palette so they follow light, dark and Increase Contrast.
enum RailTagPalette {
    static var colors: [Color] {
        [Studio.Palette.upload, Studio.Palette.good, Studio.Palette.warn, Studio.Palette.bad,
         Studio.Palette.fileTint(.audio).fillDeep, Studio.Palette.fileTint(.disc).fillDeep,
         Studio.Palette.accent, Studio.Palette.info]
    }

    /// In `colors` order.
    static var names: [String] {
        [L10n.t("Blue"), L10n.t("Green"), L10n.t("Orange"), L10n.t("Red"),
         L10n.t("Yellow"), L10n.t("Purple"), L10n.t("Teal"), L10n.t("Indigo")]
    }

    /// The user's pick, else stable per tag name.
    static func color(for tag: String, raw: String) -> Color {
        let palette = colors
        let slot = TagColors.slot(for: tag, overrides: TagColors.decode(raw), slots: palette.count)
        return palette[slot]
    }
}

extension ServerReachability {
    /// The live dot's colour in the Studio palette.
    var studioTint: Color {
        switch self {
        case .unknown: return Studio.Palette.ink3
        case .online: return Studio.Palette.good
        case .offline: return Studio.Palette.bad
        }
    }

    /// The glyph that says the same as the colour, for Differentiate Without Colour: each state
    /// has its own shape.
    var studioSymbol: String {
        switch self {
        case .unknown: return "ellipsis.circle"
        case .online: return "checkmark.circle.fill"
        case .offline: return "xmark.circle.fill"
        }
    }
}
