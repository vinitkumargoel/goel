import SwiftUI

/// The system font at a point size that follows the text-size setting: the same
/// `@ScaledMetric` factor `.studioFont(_:)` applies. New UI uses `.studioFont`; this is for the
/// rare system-font glyph that has no Studio style (`FontScalingDriftTests` accepts either).
private struct ScaledSystemFont: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var factor: CGFloat = 100

    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    let monospacedDigit: Bool

    func body(content: Content) -> some View {
        let scaled = size * factor / 100
        let font = Font.system(size: scaled, weight: weight, design: design)
        return content.font(monospacedDigit ? font.monospacedDigit() : font)
    }
}

extension View {
    func scaledFont(size: CGFloat,
                    weight: Font.Weight = .regular,
                    design: Font.Design = .default,
                    monospacedDigit: Bool = false) -> some View {
        modifier(ScaledSystemFont(size: size, weight: weight,
                                  design: design, monospacedDigit: monospacedDigit))
    }
}
