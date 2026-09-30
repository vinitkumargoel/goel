import SwiftUI

/// Type, radius, spacing and fill tokens. Views take sizes from here instead of
/// inventing a new half-point value; route text through `.scaledFont(size:)` so the
/// app's text-size setting reaches it.
extension Theme {
    enum TextSize {
        /// Uppercase section labels, badges.
        static let caption: CGFloat = 10.5
        /// Secondary row text: status, dates, byte counts.
        static let meta: CGFloat = 11.5
        /// Body and form text.
        static let body: CGFloat = 12.5
        /// Row titles, emphasised values.
        static let title: CGFloat = 13.5
        /// Sheet and pane titles.
        static let sheet: CGFloat = 15
    }

    enum Radius {
        static let chip: CGFloat = 4
        static let control: CGFloat = 7
        static let card: CGFloat = 10
        static let sheet: CGFloat = 14
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
    }

    /// Resting and hovered fills for plain controls and rows.
    static let fillRest = Color.primary.opacity(0.06)
    static let fillHover = Color.primary.opacity(0.10)
    static let rowHover = Color.primary.opacity(0.05)
}

/// A small glyph button with a 22 pt hit target, a hover fill and a tooltip that
/// doubles as its accessibility label.
struct IconButton: View {
    let symbol: String
    let help: String
    var size: CGFloat = 11
    var tint: Color? = nil
    /// VoiceOver label when the tooltip alone is too terse ("Cancel" vs "Cancel transfer of x").
    var spokenLabel: String? = nil
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Circle().fill(hovered ? Theme.fillHover : Color.clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(tint ?? Color.secondary)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(spokenLabel ?? help)
    }
}

/// The tinted pill used for secondary actions (Retry, Folder, Copy…). `prominent`
/// fills with the tint and picks contrast-safe ink via `WCAG`.
struct TintedPillButtonStyle: ButtonStyle {
    var tint: Color = Theme.accent
    var ink: Color? = nil
    var prominent = false
    /// Stretch to share a row equally with sibling pills.
    var fillWidth = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaledFont(size: Theme.TextSize.body, weight: .semibold)
            .frame(maxWidth: fillWidth ? .infinity : nil)
            .padding(.horizontal, fillWidth ? Theme.Space.xs : Theme.Space.m)
            .frame(minHeight: 28)
            .background(prominent ? tint : tint.opacity(0.14),
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .foregroundStyle(prominent ? (ink ?? Theme.onAccent) : tint)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Rectangle())
    }
}
