import SwiftUI
import AppKit
import GoelCore

// Compatibility: shared sheet and empty-state views that lived in the old `SharedViews.swift`.
// Other areas (AddFlow, Detail, SFTP, Windows, Settings) still draw them; they move here
// unchanged until those areas are rewritten, then this file is deleted at integration.

struct SheetHeader: View {
    let systemImage: String
    let title: String
    /// A small line above the title, e.g. "Welcome to Goel°" over the step name.
    var eyebrow: String? = nil

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: systemImage)
                // Not `.white`: on the light accent themes that measured 2.00–2.42:1.
                .foregroundStyle(Theme.onAccent)
                .frame(width: 30, height: 30)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.Radius.field))
                .a11yDecorative()
            VStack(alignment: .leading, spacing: 2) {
                if let eyebrow {
                    Text(eyebrow)
                        .scaledFont(size: Theme.TextSize.caption, weight: .semibold)
                        .foregroundStyle(.secondary)
                }
                Text(title)
                    .scaledFont(size: Theme.TextSize.sheet, weight: .semibold)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer()
        }
        .padding(18)
    }
}

/// Every sheet's bottom row: optional context on the left, then Cancel and the primary action
/// on the right — ⎋ and ⏎ always land on the same two buttons.
struct SheetFooter<Leading: View, Secondary: View>: View {
    var cancelTitle: String?
    var onCancel: (() -> Void)?
    let primaryTitle: String
    var primaryDisabled = false
    let onPrimary: () -> Void
    @ViewBuilder var leading: Leading
    @ViewBuilder var secondary: Secondary

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            leading
            Spacer(minLength: Theme.Space.s)
            if let onCancel {
                Button(cancelTitle ?? L10n.t("Cancel"), role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            secondary
            Button(primaryTitle, action: onPrimary)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(primaryDisabled)
        }
        .padding(14)
    }
}

extension SheetFooter where Secondary == EmptyView {
    init(cancelTitle: String? = nil, onCancel: (() -> Void)? = nil, primaryTitle: String,
         primaryDisabled: Bool = false, onPrimary: @escaping () -> Void,
         @ViewBuilder leading: () -> Leading) {
        self.init(cancelTitle: cancelTitle, onCancel: onCancel, primaryTitle: primaryTitle,
                  primaryDisabled: primaryDisabled, onPrimary: onPrimary,
                  leading: leading, secondary: { EmptyView() })
    }
}

extension SheetFooter where Leading == EmptyView, Secondary == EmptyView {
    init(cancelTitle: String? = nil, onCancel: (() -> Void)? = nil, primaryTitle: String,
         primaryDisabled: Bool = false, onPrimary: @escaping () -> Void) {
        self.init(cancelTitle: cancelTitle, onCancel: onCancel, primaryTitle: primaryTitle,
                  primaryDisabled: primaryDisabled, onPrimary: onPrimary,
                  leading: { EmptyView() }, secondary: { EmptyView() })
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    var subtitle: String? = nil
    var symbolSize: CGFloat = 38
    var symbolStyle: HierarchicalShapeStyle = .quaternary
    /// An optional way out, e.g. "Clear search and filter" on a no-match list. Shown only when both are set.
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Theme.Space.m) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .scaledFont(size: symbolSize)
                    .foregroundStyle(symbolStyle)
                    .a11yDecorative()
                Text(title)
                    .scaledFont(size: Theme.TextSize.title)
                    .foregroundStyle(.secondary)
                if let subtitle {
                    Text(subtitle)
                        .scaledFont(size: Theme.TextSize.body)
                        // Secondary, not tertiary: this line tells the user what to do next.
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            // The button stays outside the ignored-children group, or VoiceOver can't reach it.
            .a11yGroup(label: A11y.sentence(title, subtitle))

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(TintedPillButtonStyle())
            }
        }
    }
}

struct SpeedStat: View {
    let symbol: String
    let speed: Double
    let color: Color
    var size: CGFloat = 12.5
    var minWidth: CGFloat? = nil
    var directionName: String? = nil

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).scaledFont(size: size - 1.5, weight: .bold)
            Text(speed > 0 ? speed.speedString : "—")
                .scaledFont(size: size, weight: .semibold, monospacedDigit: true)
                .frame(minWidth: minWidth, alignment: .trailing)
        }
        .foregroundStyle(speed > 0 ? color : Color.secondary)
        .a11yGroup(label: spokenDirection, value: A11y.speed(speed))
    }

    private var spokenDirection: String {
        if let directionName { return directionName }
        return symbol.contains("up") ? L10n.t("Upload speed") : L10n.t("Download speed")
    }
}

/// "Pasted from clipboard" beside a field the sheet filled in by itself, with a button to clear it.
struct PastedFromClipboardNote: View {
    var clearHelp: String = L10n.t("Clear the pasted text")
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Label(L10n.t("Pasted from clipboard"), systemImage: "doc.on.clipboard")
                .scaledFont(size: Theme.TextSize.meta)
                .foregroundStyle(.secondary)
            IconButton(symbol: "xmark", help: clearHelp, size: 9, action: onClear)
        }
    }
}
