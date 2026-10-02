import SwiftUI
import GoelCore

/// Studio buttons (`.btn`). Use through `.buttonStyle(.studio(.primary))`.
///
///     Button("Add", systemImage: "arrow.right") { … }.buttonStyle(.studio(.primary, size: .small))
///     Button("Folder", systemImage: "folder") { … }.buttonStyle(.studio())
///     Button("Remove", role: .destructive) { … }.buttonStyle(.studio(.destructive))
struct StudioButtonStyle: ButtonStyle {
    enum Variant: CaseIterable, Sendable {
        /// Accent fill: the one main action of a surface.
        case primary
        /// Card fill with a border: everything else.
        case secondary
        /// Accent-soft fill: a suggested action inside a card ("Retry in 0:12").
        case soft
        /// No fill until hovered: toolbar-ish and tertiary actions.
        case ghost
        /// Secondary chrome, red label.
        case destructive
        /// Red fill: the confirm button of a destructive dialog.
        case destructivePrimary
    }

    enum Size: CaseIterable, Sendable {
        case small, regular, large

        var height: CGFloat { self == .small ? 27 : self == .regular ? 32 : 40 }
        var padding: CGFloat { self == .small ? 10 : self == .regular ? 13 : 18 }
        var radius: CGFloat { self == .small ? Studio.Radius.small : self == .regular ? Studio.Radius.control : 12 }
        var spacing: CGFloat { self == .small ? 5 : 7 }
        var text: Studio.TextStyle {
            self == .small ? .control.size(12) : self == .regular ? .control : .control.size(14)
        }
        var icon: CGFloat { self == .small ? 12 : self == .regular ? 13 : 14 }
    }

    var variant: Variant = .secondary
    var size: Size = .regular
    /// Stretch to the available width (`.actbar .btn { flex: 1 }`).
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        StudioButtonBody(configuration: configuration, style: self)
    }
}

extension ButtonStyle where Self == StudioButtonStyle {
    static func studio(_ variant: StudioButtonStyle.Variant = .secondary,
                       size: StudioButtonStyle.Size = .regular,
                       fullWidth: Bool = false) -> StudioButtonStyle {
        StudioButtonStyle(variant: variant, size: size, fullWidth: fullWidth)
    }
}

private struct StudioButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let style: StudioButtonStyle

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.size.radius, style: .continuous)
        configuration.label
            .labelStyle(StudioButtonLabelStyle(spacing: style.size.spacing, iconSize: style.size.icon))
            .studioFont(style.size.text)
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, style.size.padding)
            .frame(minHeight: style.size.height)
            .frame(maxWidth: style.fullWidth ? .infinity : nil)
            .background {
                shape.fill(fill)
                    .studioElevation(hasLift ? .raised : .flat)
            }
            .overlay {
                if let border { shape.strokeBorder(border, lineWidth: 1) }
            }
            .studioFocusRing(isFocused, shape: shape)
            .contentShape(shape)
            .onHover { hovered = isEnabled && $0 }
            .animation(Studio.Motion.quick, value: hovered)
            .animation(Studio.Motion.quick, value: configuration.isPressed)
    }

    private var pressed: Bool { configuration.isPressed }

    // Disabled drops the accent and the lift instead of fading the whole button: a faded accent
    // fill still reads as live on the dark canvas. Filled variants turn into a neutral well.

    private var hasLift: Bool {
        guard isEnabled else { return false }
        switch style.variant {
        case .primary, .secondary, .destructive, .destructivePrimary: return !pressed
        case .soft, .ghost: return false
        }
    }

    private var fill: Color {
        guard isEnabled else { return disabledFill }
        switch style.variant {
        case .primary:
            return pressed || hovered ? Studio.Palette.accentStrong : Studio.Palette.accent
        case .destructivePrimary:
            return Studio.Palette.bad.opacity(pressed ? 0.8 : hovered ? 0.9 : 1)
        case .secondary, .destructive:
            return pressed ? Studio.Palette.segment : hovered ? Studio.Palette.well : Studio.Palette.card
        case .soft:
            return pressed ? Studio.Palette.accentLine
                : hovered ? Studio.Palette.accentLine.opacity(0.6) : Studio.Palette.accentSoft
        case .ghost:
            return pressed ? Studio.Palette.track : hovered ? Studio.Palette.segment : .clear
        }
    }

    private var foreground: Color {
        guard isEnabled else { return Studio.Palette.ink3 }
        switch style.variant {
        case .primary, .destructivePrimary: return Studio.Palette.onAccent
        case .secondary: return Studio.Palette.ink
        case .soft: return Studio.Palette.accent
        case .ghost: return hovered ? Studio.Palette.ink : Studio.Palette.ink2
        case .destructive: return Studio.Palette.bad
        }
    }

    private var border: Color? {
        switch style.variant {
        case .secondary, .destructive: return isEnabled ? Studio.Palette.hairlineStrong : Studio.Palette.hairline
        // A disabled filled button keeps its outline, so it still reads as a button on a footer
        // or well whose colour is close to the neutral fill.
        case .primary, .destructivePrimary, .soft: return isEnabled ? nil : Studio.Palette.hairlineStrong
        case .ghost: return nil
        }
    }

    private var disabledFill: Color {
        switch style.variant {
        case .primary, .destructivePrimary, .soft: return Studio.Palette.segment
        case .secondary, .destructive: return Studio.Palette.card
        case .ghost: return .clear
        }
    }
}

/// Icon and title with the button's gap; the icon is sized to sit on the text's cap height.
struct StudioButtonLabelStyle: LabelStyle {
    var spacing: CGFloat = 7
    var iconSize: CGFloat = 13

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: spacing) {
            configuration.icon
                .font(StudioFonts.font(.ui, size: iconSize, weight: 650))
            configuration.title
        }
    }
}

/// A square glyph button (`.ibtn`): 32 pt, or 26 pt small. Always give it a label.
///
///     StudioIconButton("xmark", label: "Close") { dismiss() }
///     StudioIconButton("sidebar.left", label: "Toggle Sidebar", isOn: true) { … }
struct StudioIconButton: View {
    let symbol: String
    let label: String
    var size: StudioIconButtonStyle.Size = .regular
    var bordered = false
    var isOn = false
    /// Shown in the tooltip after the label, e.g. "⌘I".
    var shortcutHint: String?
    let action: () -> Void

    init(_ symbol: String, label: String, size: StudioIconButtonStyle.Size = .regular, bordered: Bool = false,
         isOn: Bool = false, shortcutHint: String? = nil, action: @escaping () -> Void) {
        self.symbol = symbol
        self.label = label
        self.size = size
        self.bordered = bordered
        self.isOn = isOn
        self.shortcutHint = shortcutHint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(StudioIconButtonStyle(size: size, bordered: bordered, isOn: isOn))
        .help(shortcutHint.map { ShortcutHint.help(label, $0) } ?? label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

struct StudioIconButtonStyle: ButtonStyle {
    enum Size: Sendable {
        case small, regular

        var side: CGFloat { self == .small ? 26 : 32 }
        var radius: CGFloat { self == .small ? Studio.Radius.small : Studio.Radius.control }
        var glyph: CGFloat { self == .small ? 13 : 15 }
    }

    var size: Size = .regular
    var bordered = false
    var isOn = false

    func makeBody(configuration: Configuration) -> some View {
        StudioIconButtonBody(configuration: configuration, style: self)
    }
}

private struct StudioIconButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let style: StudioIconButtonStyle

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: style.size.radius, style: .continuous)
        configuration.label
            .font(StudioFonts.font(.ui, size: style.size.glyph, weight: 600))
            .foregroundStyle(style.isOn ? Studio.Palette.accent : hovered ? Studio.Palette.ink : Studio.Palette.ink2)
            .frame(width: style.size.side, height: style.size.side)
            .background {
                if style.isOn {
                    shape.fill(Studio.Palette.accentSoft)
                } else if style.bordered {
                    shape.fill(hovered ? Studio.Palette.well : Studio.Palette.card).studioElevation(.raised)
                } else {
                    shape.fill(configuration.isPressed ? Studio.Palette.track
                               : hovered ? Studio.Palette.segment : .clear)
                }
            }
            .overlay {
                if style.bordered && !style.isOn { shape.strokeBorder(Studio.Palette.hairlineStrong, lineWidth: 1) }
            }
            .studioFocusRing(isFocused, shape: shape)
            .contentShape(shape)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .onHover { hovered = isEnabled && $0 }
    }
}

/// A rounded pill toggle-button (`.chip` as a control): filters, quick options.
struct StudioPillButtonStyle: ButtonStyle {
    var isOn = false
    var size: StudioChip.Size = .regular

    func makeBody(configuration: Configuration) -> some View {
        StudioPillButtonBody(configuration: configuration, isOn: isOn, size: size)
    }
}

private struct StudioPillButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let isOn: Bool
    let size: StudioChip.Size

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var hovered = false

    var body: some View {
        configuration.label
            .labelStyle(StudioButtonLabelStyle(spacing: 6, iconSize: size == .small ? 11 : 12))
            .modifier(StudioChipChrome(isOn: isOn, size: size, hovered: hovered))
            .studioFocusRing(isFocused, shape: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
            .onHover { hovered = isEnabled && $0 }
    }
}

extension View {
    /// The Studio keyboard-focus ring: a 3 pt accent halo outside `shape` (`.field.focus`).
    func studioFocusRing<S: InsettableShape>(_ isFocused: Bool, shape: S) -> some View {
        overlay {
            if isFocused {
                shape
                    .inset(by: -2)
                    .strokeBorder(Studio.Palette.focusRing, lineWidth: 3)
                    .accessibilityHidden(true)
            }
        }
    }
}
