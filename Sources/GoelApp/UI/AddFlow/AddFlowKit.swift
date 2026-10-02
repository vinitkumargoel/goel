import SwiftUI
import GoelCore

// The add flow's sheet chrome and small form pieces (`.sheet-h`, `.sheet-f`, `.lbl`, `.help`,
// `.field.area`, `.check`, `.radio`, `.oi`). Area-local: promoted at integration if others need them.

/// The sheet header (`.sheet-h`): a leading tile or artwork, an optional eyebrow, the title and
/// trailing context.
struct AddFlowHeader<Leading: View, Trailing: View>: View {
    let title: String
    var eyebrow: String?
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: Studio.Space.m) {
            leading()
            VStack(alignment: .leading, spacing: Studio.Space.xxs) {
                if let eyebrow {
                    Text(eyebrow)
                        .studioFont(.eyebrow)
                        .foregroundStyle(Studio.Palette.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(title)
                    .studioFont(.title2)
                    .foregroundStyle(Studio.Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: Studio.Space.s)
            trailing()
        }
        .padding(.horizontal, Studio.Space.xl)
        .padding(.top, Studio.Space.section)
        .padding(.bottom, Studio.Space.m)
    }
}

extension AddFlowHeader where Leading == AddFlowSymbolTile {
    /// A header with the accent glyph tile on the left.
    init(title: String, eyebrow: String? = nil, symbol: String,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(title: title, eyebrow: eyebrow, leading: { AddFlowSymbolTile(symbol: symbol) },
                  trailing: trailing)
    }
}

extension AddFlowHeader where Leading == AddFlowSymbolTile, Trailing == EmptyView {
    init(title: String, eyebrow: String? = nil, symbol: String) {
        self.init(title: title, eyebrow: eyebrow, leading: { AddFlowSymbolTile(symbol: symbol) },
                  trailing: { EmptyView() })
    }
}

/// The 36 pt accent tile the grabber and the add steps put beside their title.
struct AddFlowSymbolTile: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .studioFont(.ui, size: 16, weight: 650)
            .foregroundStyle(Studio.Palette.accent)
            .frame(width: 36, height: 36)
            .background(Studio.Palette.accentSoft,
                        in: RoundedRectangle(cornerRadius: Studio.Radius.segment, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// The sheet footer (`.sheet-f`): well fill, a hairline on top, buttons laid out by the caller so
/// each step keeps its own keyboard shortcuts.
struct AddFlowFooter<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: Studio.Space.s) { content() }
            .padding(.horizontal, Studio.Space.xl)
            .padding(.vertical, Studio.Space.ml)
            .frame(maxWidth: .infinity)
            .background(Studio.Palette.well)
            .overlay(alignment: .top) { StudioDivider() }
    }
}

/// A form caption (`.lbl`).
struct AddFieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .studioFont(.small.weight(650))
            .foregroundStyle(Studio.Palette.ink2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Explanatory text under a control (`.help`).
struct AddHelpText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .studioFont(.caption)
            .foregroundStyle(Studio.Palette.ink3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A one-line status under a control: a tinted glyph and text ("SHA-256 — verified after…").
struct AddStatusLine: View {
    let symbol: String
    let text: String
    var tone: StudioTone = .neutral
    /// Colours the text too, not just the glyph (errors read as errors).
    var tintsText = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Studio.Space.xs) {
            Image(systemName: symbol)
                .studioFont(.ui, size: 11.5, weight: 650)
                .foregroundStyle(tone == .neutral ? Studio.Palette.ink3 : tone.foreground)
                .accessibilityHidden(true)
            Text(text)
                .studioFont(.caption)
                .foregroundStyle(tintsText ? tone.foreground : Studio.Palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A callout with actions under its message: the "Couldn’t reach…" block with Try again.
struct AddCallout<Actions: View>: View {
    var tone: StudioTone = .warn
    let symbol: String
    let message: String
    var accessibilityLabel: String?
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(alignment: .top, spacing: Studio.Space.sm) {
            Image(systemName: symbol)
                .studioFont(.ui, size: 13, weight: 650)
                .foregroundStyle(tone.foreground)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Studio.Space.s) {
                Text(message)
                    .studioFont(.callout.weight(400))
                    .foregroundStyle(Studio.Palette.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(accessibilityLabel ?? message)
                HStack(spacing: Studio.Space.s) { actions() }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Studio.Space.m)
        .padding(.vertical, Studio.Space.sm)
        .background(tone.background, in: RoundedRectangle(cornerRadius: Studio.Radius.well, style: .continuous))
    }
}

/// A multi-line text field (`.field.area`): a plain `TextEditor` in Studio field chrome, with a
/// placeholder while empty and the accent rim while focused.
struct AddTextArea: View {
    @Binding var text: String
    var placeholder: String = ""
    var height: CGFloat = 96
    var style: Studio.TextStyle = .monoBody.weight(400)
    var accessibilityLabel: String
    var accessibilityHint: String?
    /// Draws the warning rim (an input error is shown under the field).
    var isInvalid = false

    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty, !placeholder.isEmpty {
                Text(placeholder)
                    .studioFont(style.weight(400))
                    .foregroundStyle(Studio.Palette.ink3)
                    .padding(.horizontal, Studio.Space.snug)
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $text)
                .studioFont(style)
                .foregroundStyle(Studio.Palette.ink)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint(accessibilityHint ?? "")
        }
        .padding(.horizontal, Studio.Space.cozy)
        .padding(.vertical, Studio.Space.s)
        .frame(height: height)
        .modifier(StudioFieldChrome(isFocused: focused, isInvalid: isInvalid))
    }
}

/// The checkbox glyph (`.check`), including the mixed bar a folder shows.
struct AddCheckGlyph: View {
    let state: FileCheckState

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Studio.Radius.mini, style: .continuous)
        ZStack {
            if state == .off {
                shape.fill(Studio.Palette.card)
                shape.strokeBorder(Studio.Palette.hairlineStrong, lineWidth: 1.5)
            } else {
                shape.fill(Studio.Palette.accent)
                Image(systemName: state == .mixed ? "minus" : "checkmark")
                    .studioFont(.ui, size: 10, weight: 800)
                    .foregroundStyle(Studio.Palette.onAccent)
            }
        }
        .frame(width: 17, height: 17)
        .accessibilityHidden(true)
    }
}

/// The radio glyph (`.radio`): a ring, or a thick accent ring when chosen.
struct AddRadioGlyph: View {
    let isOn: Bool

    var body: some View {
        ZStack {
            Circle().fill(Studio.Palette.card)
            Circle().strokeBorder(isOn ? Studio.Palette.accent : Studio.Palette.hairlineStrong,
                                  lineWidth: isOn ? 5 : 1.5)
        }
        .frame(width: 17, height: 17)
        .accessibilityHidden(true)
    }
}

/// An option row (`.oi`): rounded, accent-soft when chosen, a quiet fill on hover, the focus ring
/// from the keyboard.
struct AddOptionRowStyle: ButtonStyle {
    var isOn = false

    func makeBody(configuration: Configuration) -> some View {
        AddOptionRowBody(configuration: configuration, isOn: isOn)
    }
}

private struct AddOptionRowBody: View {
    let configuration: ButtonStyleConfiguration
    let isOn: Bool
    @State private var hovered = false
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Studio.Radius.segment, style: .continuous)
        configuration.label
            .padding(.horizontal, Studio.Space.sm)
            .padding(.vertical, Studio.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(fill))
            .studioFocusRing(isFocused, shape: shape)
            .contentShape(shape)
            .onHover { hovered = $0 }
    }

    private var fill: Color {
        if isOn { return Studio.Palette.accentSoft }
        if configuration.isPressed { return Studio.Palette.track }
        return hovered ? Studio.Palette.segment : .clear
    }
}

/// The scroll area a list sits in: the well fill and hairline, so its edge is visible.
struct AddListWell<Content: View>: View {
    var height: CGFloat?
    var maxHeight: CGFloat?
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Studio.Radius.well, style: .continuous)
        ScrollView {
            content()
                .padding(Studio.Space.xxs)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: height)
        .frame(maxHeight: maxHeight)
        .background(shape.fill(Studio.Palette.well))
        .overlay(shape.strokeBorder(Studio.Palette.hairline, lineWidth: 1))
        .clipShape(shape)
    }
}

/// "Pasted from clipboard" with a clear button, shown while the pasted text is unchanged.
struct AddPastedNote: View {
    var clearHelp: String = L10n.t("Clear the pasted text")
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: Studio.Space.xxs) {
            Image(systemName: "doc.on.clipboard")
                .studioFont(.ui, size: 11, weight: 650)
                .foregroundStyle(Studio.Palette.accent)
                .accessibilityHidden(true)
            Text(L10n.t("Pasted from clipboard"))
                .studioFont(.caption.weight(600))
                .foregroundStyle(Studio.Palette.ink2)
            Button(action: onClear) {
                Image(systemName: "xmark")
                    .studioFont(.ui, size: 9, weight: 800)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(StudioIconButtonStyle(size: .small))
            .frame(width: 18, height: 18)
            // Drawn in an 18 pt slot, clickable over 24.
            .studioHitOutset(3)
            .help(clearHelp)
            .accessibilityLabel(clearHelp)
        }
        .padding(.leading, Studio.Space.s)
        .padding(.trailing, Studio.Space.hair)
        .frame(minHeight: 22)
        .background(Studio.Palette.accentSoft, in: Capsule())
    }
}

/// Lays chips out left to right and wraps them onto new lines, so eight type chips never clip.
struct AddChipFlow: Layout {
    var spacing: CGFloat = Studio.Space.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
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
            y += row.height + spacing
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

extension GrabbedLink.Category {
    /// The artwork family the grabber and the review rows draw for this type.
    var artKind: StudioArtKind {
        switch self {
        case .archive: return .archive
        case .video: return .video
        case .audio: return .audio
        case .image: return .image
        case .software: return .app
        case .document: return .doc
        case .other: return .other
        }
    }
}

/// Animates `body` unless Reduce Motion or the snapshot harness asks for still frames.
@MainActor
func addFlowAnimate(reduceMotion: Bool, stillFrames: Bool, _ body: () -> Void) {
    if reduceMotion || stillFrames {
        body()
    } else {
        withAnimation(Studio.Motion.quick, body)
    }
}
