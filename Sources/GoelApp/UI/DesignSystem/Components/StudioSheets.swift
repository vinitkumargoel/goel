import SwiftUI
import GoelCore

/// Modal sheet chrome (`.sheet`): a header with title, subtitle and an optional leading tile; a
/// scrolling-free content area; and a footer on the well colour. Present it with `.sheet`.
///
///     StudioSheet(title: "Add downloads", subtitle: "3 links recognised",
///                 symbol: "plus", onClose: dismiss) {
///         …content…
///     } footer: {
///         StudioSheetFooter(onCancel: dismiss, primaryTitle: "Add 3", onPrimary: add)
///     }
struct StudioSheet<Content: View, Footer: View>: View {
    let title: String
    var subtitle: String?
    /// An accent tile glyph left of the title. Use `leading` for artwork instead.
    var symbol: String?
    /// Shows a close button in the header; Esc reaches it when the footer has no Cancel.
    var onClose: (() -> Void)?
    var width: CGFloat? = 520
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: Studio.Space.m) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(StudioFonts.font(.ui, size: 16, weight: 650))
                        .foregroundStyle(Studio.Palette.accent)
                        .frame(width: 36, height: 36)
                        .background(Studio.Palette.accentSoft, in: RoundedRectangle(cornerRadius: Studio.Radius.control, style: .continuous))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .studioFont(.title2)
                        .foregroundStyle(Studio.Palette.ink)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle)
                            .studioFont(.small)
                            .foregroundStyle(Studio.Palette.ink2)
                    }
                }
                Spacer(minLength: Studio.Space.s)
                if let onClose {
                    StudioIconButton("xmark", label: L10n.t("Close"), size: .small, action: onClose)
                }
            }
            .padding(.horizontal, Studio.Space.xl)
            .padding(.top, 18)
            .padding(.bottom, Studio.Space.m)

            VStack(alignment: .leading, spacing: Studio.Space.ml) {
                content()
            }
            .padding(.horizontal, Studio.Space.xl)
            .padding(.top, Studio.Space.xxs)
            .padding(.bottom, Studio.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)

            footer()
        }
        .frame(width: width)
        .background(Studio.Palette.sheet)
        .background {
            // Esc closes a sheet that has no Cancel button of its own.
            if let onClose {
                Button(L10n.t("Close"), action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                        .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
            }
        }
    }
}

extension StudioSheet where Footer == EmptyView {
    init(title: String, subtitle: String? = nil, symbol: String? = nil, onClose: (() -> Void)? = nil,
         width: CGFloat? = 520, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, symbol: symbol, onClose: onClose, width: width,
                  content: content, footer: { EmptyView() })
    }
}

/// The sheet footer (`.sheet-f`): optional context on the left, then Cancel (Esc) and the primary
/// action. The primary answers both ↩ (the default button) and ⌘↩, so it still fires from a
/// multi-line text field where ↩ inserts a newline.
struct StudioSheetFooter<Leading: View>: View {
    var cancelTitle: String = L10n.t("Cancel")
    var onCancel: (() -> Void)?
    let primaryTitle: String
    var primarySymbol: String?
    var primaryRole: ButtonRole?
    var primaryEnabled = true
    /// Draws the ⌘↩ caps beside the primary button.
    var showsShortcutHint = false
    let onPrimary: () -> Void
    @ViewBuilder var leading: () -> Leading

    var body: some View {
        HStack(spacing: Studio.Space.s) {
            leading()
            Spacer(minLength: Studio.Space.s)
            if let onCancel {
                Button(cancelTitle, role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.studio(.ghost))
            }
            if showsShortcutHint {
                StudioKeyCaps("⌘↩")
            }
            primaryButton
                .keyboardShortcut(.defaultAction)
                .disabled(!primaryEnabled)
                .background {
                    Button(primaryTitle, action: onPrimary)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!primaryEnabled)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
        }
        .padding(.horizontal, Studio.Space.xl)
        .padding(.vertical, Studio.Space.ml)
        .frame(maxWidth: .infinity)
        .background(Studio.Palette.well)
        .overlay(alignment: .top) { StudioDivider() }
    }

    @ViewBuilder private var primaryButton: some View {
        let style: StudioButtonStyle.Variant = primaryRole == .destructive ? .destructivePrimary : .primary
        if let primarySymbol {
            Button(primaryTitle, systemImage: primarySymbol, role: primaryRole, action: onPrimary)
                .buttonStyle(.studio(style))
        } else {
            Button(primaryTitle, role: primaryRole, action: onPrimary)
                .buttonStyle(.studio(style))
        }
    }
}

extension StudioSheetFooter where Leading == EmptyView {
    init(cancelTitle: String = L10n.t("Cancel"), onCancel: (() -> Void)? = nil, primaryTitle: String,
         primarySymbol: String? = nil, primaryRole: ButtonRole? = nil, primaryEnabled: Bool = true,
         showsShortcutHint: Bool = false, onPrimary: @escaping () -> Void) {
        self.init(cancelTitle: cancelTitle, onCancel: onCancel, primaryTitle: primaryTitle,
                  primarySymbol: primarySymbol, primaryRole: primaryRole, primaryEnabled: primaryEnabled,
                  showsShortcutHint: showsShortcutHint, onPrimary: onPrimary, leading: { EmptyView() })
    }
}

/// Popover chrome: optional title row, content with the mockup's padding, on the raised surface.
/// Use inside `.popover { StudioPopover(title: …) { … } }`.
struct StudioPopover<Content: View>: View {
    var title: String?
    var subtitle: String?
    var width: CGFloat? = 280
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.sm) {
            if let title {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .studioFont(.title3)
                        .foregroundStyle(Studio.Palette.ink)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle).studioFont(.small).foregroundStyle(Studio.Palette.ink3)
                    }
                }
            }
            content()
        }
        .padding(Studio.Space.ml)
        .frame(width: width, alignment: .leading)
        .background(Studio.Palette.cardRaised)
    }
}

/// A menu-style row for popovers and custom menus (`.mi`): glyph, title, shortcut, hover in accent.
struct StudioMenuRow: View {
    var symbol: String?
    let title: String
    var shortcut: String?
    var isChecked = false
    var isDestructive = false
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Studio.Space.sm) {
                if isChecked {
                    Image(systemName: "checkmark")
                        .font(StudioFonts.font(.ui, size: 12, weight: 700))
                        .foregroundStyle(hovered ? Studio.Palette.onAccent : Studio.Palette.accent)
                        .frame(width: 15)
                } else if let symbol {
                    Image(systemName: symbol)
                        .font(StudioFonts.font(.ui, size: 13, weight: 600))
                        .foregroundStyle(hovered ? Studio.Palette.onAccent : isDestructive ? Studio.Palette.bad : Studio.Palette.ink3)
                        .frame(width: 15)
                }
                Text(title)
                    .studioFont(.body)
                    .lineLimit(1)
                Spacer(minLength: Studio.Space.l)
                if let shortcut {
                    Text(shortcut)
                        .studioFont(.monoSmall)
                        .foregroundStyle(hovered ? Studio.Palette.onAccent : Studio.Palette.ink3)
                }
            }
            .foregroundStyle(hovered ? Studio.Palette.onAccent : isDestructive ? Studio.Palette.bad : Studio.Palette.ink)
            .padding(.horizontal, Studio.Space.sm)
            .frame(minHeight: 30)
            .background(hovered ? Studio.Palette.accent : .clear,
                        in: RoundedRectangle(cornerRadius: Studio.Radius.small, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel(title)
        .accessibilityAddTraits(isChecked ? .isSelected : [])
    }
}
