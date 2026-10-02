import XCTest
import AppKit
@testable import GoelApp

/// The focus ring is the keyboard user's only cue, so it must clear the 3:1 that WCAG 1.4.11
/// asks of a state indicator, against every surface a focusable control sits on.
final class FocusRingContrastTests: XCTestCase {

    private func components(_ color: OKLCH) -> (r: Double, g: Double, b: Double) {
        let srgb = color.nsColor.usingColorSpace(.sRGB)!
        func clamp(_ value: CGFloat) -> Double { Double(min(1, max(0, value))) }
        return (clamp(srgb.redComponent), clamp(srgb.greenComponent), clamp(srgb.blueComponent))
    }

    /// `foreground` drawn over `background` (its alpha honoured), as 0xRRGGBB.
    private func composite(_ foreground: OKLCH, over background: UInt32) -> UInt32 {
        let fg = components(foreground)
        let a = foreground.alpha
        func mix(_ top: Double, _ shift: UInt32) -> UInt32 {
            let bottom = Double((background >> shift) & 0xFF) / 255
            return UInt32(((top * a + bottom * (1 - a)) * 255).rounded()) << shift
        }
        return mix(fg.r, 16) | mix(fg.g, 8) | mix(fg.b, 0)
    }

    func testFocusRingClearsThreeToOneOnEverySurface() {
        let tones = Studio.Tones.self
        let surfaces: [(String, StudioColorToken)] = [
            ("canvas", tones.canvas), ("card", tones.card), ("rail", tones.rail), ("well", tones.well),
        ]
        let variants = [
            AppearanceVariant(isDark: false, isHighContrast: false), AppearanceVariant(isDark: true, isHighContrast: false),
            AppearanceVariant(isDark: false, isHighContrast: true), AppearanceVariant(isDark: true, isHighContrast: true),
        ]
        for (name, surface) in surfaces {
            for variant in variants {
                let window: UInt32 = variant.isDark ? 0x000000 : 0xFFFFFF
                let background = composite(surface.resolve(variant), over: window)
                let ring = composite(tones.focusRing.resolve(variant), over: background)
                let ratio = WCAG.contrastRatio(ring, background)
                XCTAssertGreaterThanOrEqual(ratio, 3, "focus ring on \(name), dark: \(variant.isDark), "
                                            + "increase contrast: \(variant.isHighContrast)")
            }
        }
    }
}
