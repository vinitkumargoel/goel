import SwiftUI

/// Design tokens shared by the app **and** the widget extension.
///
/// Every value here is lifted verbatim from `visual.html` — the `:root` token block and the
/// `figcaption .spec` notes. Do not approximate them and do not "improve" them.
///
/// Two rules govern which colours are explicit hex and which are system colours:
///
/// * **Structural greys** (ground, elevations, label ramp, separator) are system colours.
///   The mockup's dark values *are* the system values — `#1C1C1E` is
///   `secondarySystemGroupedBackground` in dark, `rgba(235,235,245,.60)` is `secondaryLabel`
///   in dark, `rgba(84,84,88,.65)` is `separator` in dark — so using the system colour is both
///   pixel-exact and keeps Increase Contrast / Reduce Transparency working.
/// * **Brand and semantic accents** (ember, instrument, success/danger/warning) are explicit,
///   because the mockup deliberately re-tones them per appearance for contrast
///   (ember `#FF6B2C` dark → `#E85D18` light).
///
/// Keep this file free of app-only types. Both targets compile it.
public enum SharedTheme {

    // MARK: - Brand

    /// Active transfer, primary CTA, progress fill.
    /// `#FF6B2C` dark · `#E85D18` light (shifted for AA contrast on a light ground).
    public static let ember: Color = adaptiveColor(dark: 0xFF_6B_2C, light: 0xE8_5D_18)

    /// The leading (top) stop of the ember gradient — `linear-gradient(90deg, #FF8A4C, #FF6B2C)`.
    /// Light mode uses `#FF7A38`, the mockup's own lightened ember.
    public static let emberBright: Color = adaptiveColor(dark: 0xFF_8A_4C, light: 0xFF_7A_38)

    /// Secondary data channel: SFTP, sparkline alternate, informational glyphs.
    /// `#5AC8FA` dark · `#0B7FA8` light.
    public static let instrument: Color = adaptiveColor(dark: 0x5A_C8_FA, light: 0x0B_7F_A8)

    // MARK: - Ground and elevation

    /// `#000000` dark (OLED base) · `#F2F2F7` light.
    public static let ground = Color(uiColor: .systemGroupedBackground)

    /// Cards. `#1C1C1E` dark · `#FFFFFF` light.
    public static let elev1 = Color(uiColor: .secondarySystemGroupedBackground)

    /// Controls, row icon chips, ghost buttons. `#2C2C2E` dark · `#E5E5EA` light.
    public static let elev2 = Color(uiColor: .systemGray5)

    /// Raised / selected surfaces, idle segment fill. `#3A3A3C` dark · `#D1D1D6` light.
    public static let elev3 = Color(uiColor: .systemGray4)

    // MARK: - Label ramp

    /// Primary label. `#FFFFFF` dark · `#000000` light.
    public static let label1 = Color(uiColor: .label)

    /// Secondary label. `rgba(235,235,245,.60)` dark.
    public static let label2 = Color(uiColor: .secondaryLabel)

    /// Tertiary label. `rgba(235,235,245,.30)` dark.
    public static let label3 = Color(uiColor: .tertiaryLabel)

    /// Hairline rules. `rgba(84,84,88,.65)` dark.
    public static let separator = Color(uiColor: .separator)

    // MARK: - Semantic (reserved)

    /// Verified / complete. **Never** decoration. `#30D158` dark · `#28A745` light.
    public static let success: Color = adaptiveColor(dark: 0x30_D1_58, light: 0x28_A7_45)

    /// Failure / destructive. **Never** decoration. `#FF453A` dark · `#FF3B30` light.
    public static let danger: Color = adaptiveColor(dark: 0xFF_45_3A, light: 0xFF_3B_30)

    /// Caution. **Never** decoration. `#FF9F0A` dark · `#FF9500` light.
    public static let warning: Color = adaptiveColor(dark: 0xFF_9F_0A, light: 0xFF_95_00)

    // MARK: - Metrics the widget extension also needs

    /// Live Activity and Home Screen widget corner radius.
    public static let widgetRadius: CGFloat = 22

    /// Progress bar thickness — fully rounded.
    public static let progressBar: CGFloat = 4

    /// Segment bar thickness (radius 3.5).
    public static let segmentBar: CGFloat = 7

    /// The ember gradient used for active progress and segment fills.
    /// `linear-gradient(90deg, #FF8A4C, #FF6B2C)` — leading to trailing.
    public static var emberGradient: LinearGradient {
        LinearGradient(
            colors: [emberBright, ember],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

// MARK: - Appearance-adaptive construction

/// Builds a colour that resolves per `userInterfaceStyle`, so it tracks the trait automatically
/// rather than being snapshotted at first read.
///
/// - Parameters:
///   - dark: 24-bit sRGB value used in dark appearance.
///   - light: 24-bit sRGB value used in light appearance.
///   - alpha: constant opacity applied to both.
private func adaptiveColor(dark: UInt32, light: UInt32, alpha: CGFloat = 1) -> Color {
    let darkColor = sRGBColor(dark, alpha: alpha)
    let lightColor = sRGBColor(light, alpha: alpha)
    return Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark ? darkColor : lightColor
    })
}

/// Builds a colour from a 24-bit `0xRRGGBB` sRGB value.
private func sRGBColor(_ hex: UInt32, alpha: CGFloat = 1) -> UIColor {
    UIColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}
