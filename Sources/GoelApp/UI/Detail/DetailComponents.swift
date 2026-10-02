import SwiftUI
import GoelCore

/// One line of a facts list (`.facts`): a tertiary key on the left, the value right-aligned, and
/// an optional copy button. Copy always copies the full value, even when a shorter one is shown.
struct DetailFactRow<Value: View>: View {
    let key: String
    var copyValue: String?
    /// What VoiceOver reads as the row's value.
    var spokenValue: String
    @ViewBuilder var value: () -> Value

    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Studio.Space.l) {
            Text(key)
                .studioFont(.callout.weight(400))
                .foregroundStyle(Studio.Palette.ink3)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 0)
            value()
            if let copyValue {
                DetailCopyButton(help: L10n.t("Copy %@", L10n.midSentence(L10n.t(key)))) {
                    vm.copyToPasteboard(copyValue)
                }
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(key)
        .accessibilityValue(spokenValue)
    }
}

extension DetailFactRow where Value == DetailFactText {
    /// A plain text value: `tone` tints it, `mono` sets it in the data face, `display` replaces
    /// what is drawn (an abbreviated path) while `value` stays what is copied and spoken.
    init(_ key: String, value: String, display: String? = nil, tone: StudioTone? = nil,
         mono: Bool = false, copyable: Bool = false) {
        self.init(key: key, copyValue: copyable ? value : nil, spokenValue: value) {
            DetailFactText(text: display ?? value, help: display == nil ? nil : value, tone: tone, mono: mono)
        }
    }
}

struct DetailFactText: View {
    let text: String
    var help: String?
    var tone: StudioTone?
    var mono = false

    var body: some View {
        Text(text)
            .studioFont(mono ? .monoBody : .callout.weight(550))
            .foregroundStyle(tone?.foreground ?? Studio.Palette.ink)
            .multilineTextAlignment(.trailing)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help(help ?? text)
    }
}

/// The 20 pt copy glyph that sits after a fact's value.
struct DetailCopyButton: View {
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "doc.on.doc")
                .font(StudioFonts.font(.ui, size: 10.5, weight: 600))
                .foregroundStyle(hovered ? Studio.Palette.accent : Studio.Palette.ink3)
                .frame(width: 20, height: 20)
                .background(hovered ? Studio.Palette.segment : .clear,
                            in: RoundedRectangle(cornerRadius: Studio.Radius.badge, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A facts list: rows 9 pt apart, the mockup's `dl.facts`.
struct DetailFacts<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A titled section (`.sect`): eyebrow header with trailing detail, then content 8 pt below.
struct DetailSection<Trailing: View, Content: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.s) {
            StudioSectionHeader(title, trailing: trailing)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension DetailSection where Trailing == DetailSectionDetail {
    init(_ title: String, detail: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, trailing: { DetailSectionDetail(text: detail) }, content: content)
    }
}

struct DetailSectionDetail: View {
    let text: String?

    var body: some View {
        if let text {
            Text(text).studioFont(.monoSmall).foregroundStyle(Studio.Palette.ink3).lineLimit(1)
        }
    }
}

/// A quiet placeholder line inside a section ("No active peers").
struct DetailEmptyLine: View {
    let text: String

    var body: some View {
        Text(text)
            .studioFont(.small)
            .foregroundStyle(Studio.Palette.ink3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Studio.Space.xxs)
    }
}

/// "↓ 12 MB/s" in the accent, "↑ 640 KB/s" in the upload tone; "—" when idle.
struct DetailSpeedText: View {
    enum Direction { case down, up }

    let direction: Direction
    let speed: Double
    var style: Studio.TextStyle = .mono
    var showsIdle = true

    var body: some View {
        let arrow = direction == .down ? "↓" : "↑"
        let active = speed >= 1
        if active || showsIdle {
            Text(verbatim: active ? "\(arrow) \(speed.speedString)" : "\(arrow) —")
                .studioFont(style)
                .foregroundStyle(active ? (direction == .down ? Studio.Palette.accent : Studio.Palette.upload)
                                        : Studio.Palette.ink3)
                .lineLimit(1)
                .accessibilityLabel(direction == .down ? L10n.t("Download %@", A11y.speed(speed))
                                                       : L10n.t("upload %@", A11y.speed(speed)))
        }
    }
}

/// Wraps its children onto as many rows as they need: action rows in a 360 pt sheet.
struct DetailFlowLayout: Layout {
    var spacing: CGFloat = Studio.Space.xs
    var lineSpacing: CGFloat = Studio.Space.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
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

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
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

/// A Studio-chrome pull-down: the label is drawn by the button style, the items are a native
/// menu. `.menuStyle(.button)` keeps the custom label instead of AppKit's pop-up look.
struct DetailMenuButton<Items: View>: View {
    let title: String
    var symbol: String?
    var variant: StudioButtonStyle.Variant = .secondary
    var size: StudioButtonStyle.Size = .small
    var showsChevron = true
    var fullWidth = false
    var accessibilityLabel: String?
    @ViewBuilder var items: () -> Items

    var body: some View {
        Menu {
            items()
        } label: {
            HStack(spacing: size == .small ? 5 : 7) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(StudioFonts.font(.ui, size: size == .small ? 12 : 13, weight: 650))
                }
                Text(title)
                if showsChevron {
                    Image(systemName: "chevron.down")
                        .font(StudioFonts.font(.ui, size: 9, weight: 700))
                        .foregroundStyle(Studio.Palette.ink3)
                }
            }
            .frame(maxWidth: fullWidth ? .infinity : nil)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.studio(variant, size: size, fullWidth: fullWidth))
        .fixedSize(horizontal: !fullWidth, vertical: true)
        .accessibilityLabel(accessibilityLabel ?? title)
    }
}
