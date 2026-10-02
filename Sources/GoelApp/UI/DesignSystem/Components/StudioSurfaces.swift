import SwiftUI
import GoelCore

/// Which fill a Studio surface takes.
enum StudioSurface: Sendable {
    case card, well, raised, sheet

    var color: Color {
        switch self {
        case .card: return Studio.Palette.card
        case .well: return Studio.Palette.well
        case .raised: return Studio.Palette.cardRaised
        case .sheet: return Studio.Palette.sheet
        }
    }
}

extension View {
    /// Card chrome on any view: fill, 1 pt rim, layered shadow, optional 2 pt selection ring.
    /// The dark variant adds the mockup's faint inner top highlight.
    func studioSurface(_ surface: StudioSurface = .card,
                       radius: CGFloat = Studio.Radius.card,
                       elevation: Studio.Elevation = .card,
                       isSelected: Bool = false) -> some View {
        modifier(StudioSurfaceChrome(surface: surface, radius: radius, elevation: elevation, isSelected: isSelected))
    }
}

private struct StudioSurfaceChrome: ViewModifier {
    let surface: StudioSurface
    let radius: CGFloat
    let elevation: Studio.Elevation
    let isSelected: Bool

    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        // Only the content is clipped (an artwork band hugging the top corners); the shadow sits
        // on the background shape outside the clip.
        content
            .clipShape(shape)
            .background(shape.fill(surface.color).studioElevation(elevation))
            .overlay {
                if isSelected {
                    shape.strokeBorder(Studio.Palette.accent, lineWidth: 2)
                } else {
                    shape.strokeBorder(Studio.Palette.cardEdge, lineWidth: 1)
                }
            }
            .overlay {
                if colorScheme == .dark && elevation.darkTopHighlight > 0 && !isSelected {
                    shape.inset(by: 0.5)
                        .stroke(LinearGradient(colors: [Color.white.opacity(elevation.darkTopHighlight * 2), .clear],
                                               startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.06)),
                                lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// A card (`.card`). Padding defaults to the mockup's 16 pt; pass 0 for edge-to-edge content.
///
///     StudioCard { … }
///     StudioCard(padding: 0, radius: Studio.Radius.boardCard, isSelected: true) { … }
struct StudioCard<Content: View>: View {
    var padding: CGFloat = Studio.Space.l
    var radius: CGFloat = Studio.Radius.card
    var surface: StudioSurface = .card
    var elevation: Studio.Elevation = .card
    var isSelected = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .studioSurface(surface, radius: radius, elevation: elevation, isSelected: isSelected)
    }
}

/// An inset well (`.well`): a quieter surface for grouped facts inside a card or sheet.
struct StudioWell<Content: View>: View {
    var padding: CGFloat = Studio.Space.m
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Studio.Radius.well, style: .continuous)
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(Studio.Palette.well))
            .overlay(shape.strokeBorder(Studio.Palette.hairline, lineWidth: 1))
    }
}

/// An inline callout (`.note`): neutral, accent, warn or bad.
struct StudioNote<Accessory: View>: View {
    var tone: StudioTone = .neutral
    var symbol: String?
    let message: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .top, spacing: Studio.Space.sm) {
            if let symbol {
                Image(systemName: symbol)
                    .font(StudioFonts.font(.ui, size: 13, weight: 650))
                    .foregroundStyle(tone == .neutral ? Studio.Palette.ink3 : tone.foreground)
                    .accessibilityHidden(true)
            }
            Text(message)
                .studioFont(.callout.weight(400))
                .foregroundStyle(tone == .neutral ? Studio.Palette.ink2 : Studio.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            accessory()
        }
        .padding(.horizontal, Studio.Space.m)
        .padding(.vertical, Studio.Space.sm)
        .background(tone.background, in: RoundedRectangle(cornerRadius: Studio.Radius.well, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

extension StudioNote where Accessory == EmptyView {
    init(tone: StudioTone = .neutral, symbol: String? = nil, message: String) {
        self.init(tone: tone, symbol: symbol, message: message, accessory: { EmptyView() })
    }
}

/// A statistic tile (`.stat`): big display number, a unit and a caption.
struct StudioStatTile: View {
    let value: String
    var unit: String?
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value).studioFont(.stat)
                if let unit {
                    Text(unit).studioFont(.bodyStrong).foregroundStyle(Studio.Palette.ink2)
                }
            }
            .foregroundStyle(Studio.Palette.ink)
            Text(caption)
                .studioFont(.caption.weight(600))
                .foregroundStyle(Studio.Palette.ink3)
        }
        .padding(Studio.Space.ml)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Studio.Palette.well, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Studio.Palette.hairline, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
        .accessibilityValue([value, unit].compactMap { $0 }.joined(separator: " "))
    }
}

/// A 1 pt divider in the hairline colour.
struct StudioDivider: View {
    var strong = false

    var body: some View {
        Rectangle()
            .fill(strong ? Studio.Palette.hairlineStrong : Studio.Palette.hairline)
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}
