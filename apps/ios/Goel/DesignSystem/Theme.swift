import SwiftUI

/// The app's design tokens — colours, metrics, and the type scale — lifted from `visual.html`.
///
/// The colour subset the widget extension also needs lives in `SharedTheme` and is forwarded
/// here, so the two targets can never drift apart. Views must never write a colour or a metric
/// literal: if a value is missing from this file, add it here first.
public enum Theme {

    // MARK: - Colour

    /// - Important: inside this namespace the bare name `Color` resolves to `Theme.Color`.
    ///   Every property below therefore spells its type `SwiftUI.Color`.
    public enum Color {

        // MARK: Brand — forwarded from SharedTheme

        /// Active transfer, primary CTA, progress fill. `#FF6B2C` dark · `#E85D18` light.
        public static let ember: SwiftUI.Color = SharedTheme.ember
        /// Leading stop of the ember gradient. `#FF8A4C` dark · `#FF7A38` light.
        public static let emberBright: SwiftUI.Color = SharedTheme.emberBright
        /// Secondary data channel: SFTP, sparkline alternate. `#5AC8FA` dark · `#0B7FA8` light.
        public static let instrument: SwiftUI.Color = SharedTheme.instrument

        // MARK: Ground and elevation

        /// `#000000` dark · `#F2F2F7` light.
        public static let ground: SwiftUI.Color = SharedTheme.ground
        /// Cards. `#1C1C1E` dark · `#FFFFFF` light.
        public static let elev1: SwiftUI.Color = SharedTheme.elev1
        /// Controls and row icon chips. `#2C2C2E` dark · `#E5E5EA` light.
        public static let elev2: SwiftUI.Color = SharedTheme.elev2
        /// Raised surfaces and idle segment fill. `#3A3A3C` dark · `#D1D1D6` light.
        public static let elev3: SwiftUI.Color = SharedTheme.elev3

        // MARK: Label ramp

        /// Primary label.
        public static let label1: SwiftUI.Color = SharedTheme.label1
        /// Secondary label. `rgba(235,235,245,.60)` dark.
        public static let label2: SwiftUI.Color = SharedTheme.label2
        /// Tertiary label. `rgba(235,235,245,.30)` dark.
        public static let label3: SwiftUI.Color = SharedTheme.label3
        /// Hairline rules. `rgba(84,84,88,.65)` dark.
        public static let separator: SwiftUI.Color = SharedTheme.separator

        // MARK: Semantic — reserved, never decoration

        /// Verified / complete. `#30D158` dark · `#28A745` light.
        public static let success: SwiftUI.Color = SharedTheme.success
        /// Failure / destructive. `#FF453A` dark · `#FF3B30` light.
        public static let danger: SwiftUI.Color = SharedTheme.danger
        /// Caution. `#FF9F0A` dark · `#FF9500` light.
        public static let warning: SwiftUI.Color = SharedTheme.warning

        // MARK: App-only

        /// The unfilled part of a progress or segment track.
        /// `rgba(120,120,128,.32)` dark · `rgba(120,120,128,.20)` light, straight off the mockup.
        public static let idleTrack = SwiftUI.Color(uiColor: UIColor { traits in
            UIColor(
                red: 120 / 255,
                green: 120 / 255,
                blue: 128 / 255,
                alpha: traits.userInterfaceStyle == .dark ? 0.32 : 0.20
            )
        })

        /// Active progress and segment fill: `linear-gradient(90deg, #FF8A4C, #FF6B2C)`.
        public static var emberGradient: LinearGradient { SharedTheme.emberGradient }
    }

    // MARK: - Metric

    /// Point sizes read off the `figcaption .spec` blocks in `visual.html`.
    public enum Metric {
        /// Progress bar thickness — fully rounded.
        public static let progressBar: CGFloat = SharedTheme.progressBar
        /// Segment bar thickness.
        public static let segmentBar: CGFloat = SharedTheme.segmentBar
        /// Segment bar corner radius — exactly half of ``segmentBar``.
        public static let segmentRadius: CGFloat = 3.5
        /// Row icon chip edge.
        public static let rowIcon: CGFloat = 38
        /// Row icon chip corner radius.
        public static let rowIconRadius: CGFloat = 10
        /// Card corner radius.
        public static let cardRadius: CGFloat = 14
        /// Horizontal screen gutter, and the inset for cards and grouped lists.
        public static let gutter: CGFloat = 16
        /// Separator thickness.
        public static let hairline: CGFloat = 0.5
        /// Leading inset of a row separator.
        public static let separatorInset: CGFloat = 16
        /// System switch size — do not restyle.
        public static let switchSize = CGSize(width: 51, height: 31)
        /// Live Activity and Home Screen widget corner radius.
        public static let widgetRadius: CGFloat = SharedTheme.widgetRadius
        /// Player scrubber track thickness.
        public static let scrubberTrack: CGFloat = 6
        /// Player scrubber knob diameter.
        public static let scrubberKnob: CGFloat = 13
        /// Minimum tappable edge. Non-negotiable.
        public static let minHitTarget: CGFloat = 44
        /// Vertical padding inside a queue row — `.row { padding: 12px 16px }`.
        public static let rowVerticalPadding: CGFloat = 12
    }

    // MARK: - Typography

    /// The mockup's type scale.
    ///
    /// Sizes are exact so a screenshot lines up with `visual.html` at the default content size.
    /// `Font.system(size:)` does not scale on its own, so for Dynamic Type call sites pair these
    /// with `@ScaledMetric(relativeTo:)` over the matching value in ``Size``, e.g.
    /// `@ScaledMetric(relativeTo: .subheadline) private var titleSize = Theme.Typo.Size.rowTitle`.
    public enum Typo {

        /// Raw point sizes, for `@ScaledMetric` call sites.
        public enum Size {
            public static let rowTitle: CGFloat = 15
            public static let rowSubtitle: CGFloat = 12.5
            public static let bigNumber: CGFloat = 52
            public static let bigNumberUnit: CGFloat = 24
            public static let detailTitle: CGFloat = 19
            public static let sectionLabel: CGFloat = 11
            public static let statLabel: CGFloat = 10.5
            public static let statValue: CGFloat = 16
            public static let mono: CGFloat = 11
            public static let caption: CGFloat = 11.5
        }

        /// Tracking for uppercase section labels — `letter-spacing: .07em` at 11 pt.
        /// Apply with `.tracking(Theme.Typo.sectionTracking)` at the call site.
        public static let sectionTracking: CGFloat = 0.6

        /// Tracking for uppercase stat labels — `letter-spacing: .05em` at 10.5 pt.
        public static let statTracking: CGFloat = 0.5

        /// Queue row filename — 15 pt semibold.
        public static let rowTitle = Font.system(size: Size.rowTitle, weight: .semibold)

        /// Queue row status line — 12.5 pt regular. Add `.monospacedDigit()` at the call site.
        public static let rowSubtitle = Font.system(size: Size.rowSubtitle, weight: .regular)

        /// Detail hero percentage — 52 pt bold, tabular.
        public static let bigNumber = Font.system(size: Size.bigNumber, weight: .bold)
            .monospacedDigit()

        /// The `%` beside ``bigNumber`` — 24 pt semibold, secondary.
        public static let bigNumberUnit = Font.system(size: Size.bigNumberUnit, weight: .semibold)

        /// Detail hero filename — 19 pt semibold.
        public static let detailTitle = Font.system(size: Size.detailTitle, weight: .semibold)

        /// Card heading — 11 pt semibold, uppercased. Add `.tracking(sectionTracking)`.
        public static let sectionLabel = Font.system(size: Size.sectionLabel, weight: .semibold)

        /// Stat key — 10.5 pt regular, uppercased, tertiary. Add `.tracking(statTracking)`.
        public static let statLabel = Font.system(size: Size.statLabel, weight: .regular)

        /// Stat value — 16 pt semibold, tabular.
        public static let statValue = Font.system(size: Size.statValue, weight: .semibold)
            .monospacedDigit()

        /// Host / mirror line — 11 pt monospaced.
        public static let mono = Font.system(size: Size.mono, weight: .regular, design: .monospaced)

        /// Scrubber timecodes, Live Activity subtitle — 11.5 pt regular.
        public static let caption = Font.system(size: Size.caption, weight: .regular)
    }
}
