import SwiftUI
import GoelCore

// Small Studio pieces the Windows area shares between its surfaces. They are named `Windows…`
// so they never clash with the design system; promote them at integration if others want them.

/// The compact card (`.mcard`): a row of artwork, text and trailing controls on a card surface.
/// `isFailure` adds the faint red inner rim (`.mcard.fail`); `isSelected` the 2 pt accent ring.
struct WindowsCompactCard<Content: View>: View {
    var isFailure = false
    var isSelected = false
    var isHovered = false
    var padding = EdgeInsets(top: 11, leading: 12, bottom: 11, trailing: 12)
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Studio.Radius.compactCard, style: .continuous)
        HStack(spacing: 11) { content() }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .studioSurface(isHovered ? .well : .card, radius: Studio.Radius.compactCard, isSelected: isSelected)
            .overlay {
                if isFailure && !isSelected {
                    shape.inset(by: 1).strokeBorder(Studio.Palette.badSoft, lineWidth: 1)
                }
            }
    }
}

/// An uppercase section label (`.eyebrow`), announced as a header.
struct WindowsEyebrow: View {
    let text: String
    var tint: Color = Studio.Palette.ink3

    init(_ text: String, tint: Color = Studio.Palette.ink3) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .studioFont(.eyebrow)
            .foregroundStyle(tint)
            .lineLimit(1)
            .accessibilityLabel(text)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A labelled field column (`.lbl` above an input).
struct WindowsLabeledField<Content: View>: View {
    let label: String
    var help: String?
    var helpTone: StudioTone = .neutral
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .studioFont(.small.weight(650))
                .foregroundStyle(Studio.Palette.ink2)
                .accessibilityHidden(true)
            content()
            if let help {
                Text(help)
                    .studioFont(.caption)
                    .foregroundStyle(helpTone == .neutral ? Studio.Palette.ink3 : helpTone.foreground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The dashed accent drop target (`.drop`). Turns solid when something hovers over it.
struct WindowsDropZone<Content: View>: View {
    var isTargeted = false
    var minHeight: CGFloat = 110
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Studio.Radius.card, style: .continuous)
        VStack(spacing: Studio.Space.s) { content() }
            .foregroundStyle(Studio.Palette.accent)
            .multilineTextAlignment(.center)
            .padding(Studio.Space.xl)
            .frame(maxWidth: .infinity, minHeight: minHeight)
            .background(shape.fill(isTargeted ? Studio.Palette.accentLine.opacity(0.5) : Studio.Palette.accentSoft))
            .overlay(shape.strokeBorder(isTargeted ? Studio.Palette.accent : Studio.Palette.accentLine,
                                        style: StrokeStyle(lineWidth: 2, dash: isTargeted ? [] : [6, 4])))
    }
}

/// Step dots (`.dots`): the current step is a 22 pt accent capsule, the rest 7 pt dots.
struct WindowsStepDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: Studio.Space.xs) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index == current ? Studio.Palette.accent
                          : index < current ? Studio.Palette.accentLine : Studio.Palette.hairlineStrong)
                    .frame(width: index == current ? 22 : 7, height: 7)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.t("Setup progress"))
        .accessibilityValue(L10n.t("Step %1$@ of %2$@", String(current + 1), String(count)))
    }
}

/// A tile glyph in a tinted rounded square, for rows that are about an action rather than a file
/// (a ready-check item, a conversion).
struct WindowsGlyphTile: View {
    let symbol: String
    var tone: StudioTone = .accent
    var side: CGFloat = 32

    var body: some View {
        Image(systemName: symbol)
            .font(StudioFonts.font(.ui, size: side * 0.44, weight: 650))
            .foregroundStyle(tone.foreground)
            .frame(width: side, height: side)
            .background(tone.background, in: RoundedRectangle(cornerRadius: side * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

extension View {
    /// A hairline under a window's top bar (`.tbar.line`).
    func windowsToolbarChrome() -> some View {
        self
            .padding(.horizontal, Studio.Space.l)
            .frame(minHeight: 50)
            .background(Studio.Palette.well)
            .overlay(alignment: .bottom) { StudioDivider() }
    }
}

/// Lays children out left to right, wrapping onto new lines (chip rows that may not fit).
struct WindowsFlowLayout: Layout {
    var spacing: CGFloat = Studio.Space.xs
    var lineSpacing: CGFloat = Studio.Space.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
