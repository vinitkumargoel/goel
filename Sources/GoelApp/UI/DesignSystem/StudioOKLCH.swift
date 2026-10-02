import AppKit

/// A colour written the way the Studio mockup writes it: `oklch(L% C h / alpha)`.
/// Converted once to Display P3 (the mockup's browser gamut on a Mac display), clamped
/// channel-wise when a value falls outside it.
struct OKLCH: Equatable, Sendable {
    /// Perceived lightness, 0…1 (the mockup's percentage divided by 100).
    var l: Double
    var c: Double
    /// Hue in degrees.
    var h: Double
    var alpha: Double = 1

    init(_ l: Double, _ c: Double, _ h: Double, alpha: Double = 1) {
        self.l = l
        self.c = c
        self.h = h
        self.alpha = alpha
    }

    func opacity(_ alpha: Double) -> OKLCH { OKLCH(l, c, h, alpha: alpha) }

    /// Returns a copy with lightness moved by `delta` (−1…1), clamped to 0…1.
    func lighter(_ delta: Double) -> OKLCH { OKLCH(min(1, max(0, l + delta)), c, h, alpha: alpha) }

    var nsColor: NSColor {
        let p3 = displayP3Components
        return NSColor(displayP3Red: p3.r, green: p3.g, blue: p3.b, alpha: CGFloat(alpha))
    }

    /// Gamma-encoded Display P3 channels, 0…1.
    var displayP3Components: (r: CGFloat, g: CGFloat, b: CGFloat) {
        let radians = h * .pi / 180
        let a = c * cos(radians)
        let b = c * sin(radians)

        // OKLab → LMS (cube roots) → LMS → linear sRGB (Björn Ottosson's reference matrices).
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let lc = l_ * l_ * l_, mc = m_ * m_ * m_, sc = s_ * s_ * s_
        let sr = 4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc
        let sg = -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc
        let sb = -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc

        // Linear sRGB → linear Display P3.
        let pr = 0.8224621 * sr + 0.1775380 * sg + 0.0000000 * sb
        let pg = 0.0331941 * sr + 0.9668058 * sg + 0.0000000 * sb
        let pb = 0.0170827 * sr + 0.0723974 * sg + 0.9105199 * sb

        return (Self.encode(pr), Self.encode(pg), Self.encode(pb))
    }

    /// The sRGB transfer curve, which Display P3 shares.
    private static func encode(_ linear: Double) -> CGFloat {
        let x = min(1, max(0, linear))
        let v = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
        return CGFloat(min(1, max(0, v)))
    }
}
