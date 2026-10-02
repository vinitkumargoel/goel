import SwiftUI

extension Studio {

    /// The type scale, taken from the mockup. Each style names its family, size, weight and
    /// tracking; `.studioFont(_:)` applies it and scales it with the text-size setting.
    struct TextStyle: Equatable, Sendable {
        var family: StudioFontFamily
        var size: CGFloat
        /// CSS-style numeric weight (400 regular, 600 semibold, 650/750 in-betweens).
        var weight: CGFloat
        /// Letter spacing in em, as the mockup writes it (-0.02em → -0.02).
        var trackingEm: CGFloat = 0
        var uppercase = false
        var tabularNumbers = false

        func weight(_ weight: CGFloat) -> TextStyle {
            var copy = self
            copy.weight = weight
            return copy
        }

        func size(_ size: CGFloat) -> TextStyle {
            var copy = self
            copy.size = size
            return copy
        }

        var tabular: TextStyle {
            var copy = self
            copy.tabularNumbers = true
            return copy
        }

        // MARK: Display (Bricolage Grotesque)

        /// 52 pt cover / onboarding hero title.
        static let hero = TextStyle(family: .display, size: 52, weight: 750, trackingEm: -0.03)
        /// 46 pt progress read-out in the detail hero ("62%").
        static let bigNumber = TextStyle(family: .display, size: 46, weight: 750, trackingEm: -0.05,
                                         tabularNumbers: true)
        /// `.h1`: 30 pt window and empty-state titles.
        static let title1 = TextStyle(family: .display, size: 30, weight: 700, trackingEm: -0.03)
        /// `.h2`: 21 pt sheet titles.
        static let title2 = TextStyle(family: .display, size: 21, weight: 650, trackingEm: -0.02)
        /// `.h3`: 16 pt card and section titles.
        static let title3 = TextStyle(family: .display, size: 16, weight: 650, trackingEm: -0.01)
        /// Lane names on the board ("Downloading").
        static let lane = TextStyle(family: .display, size: 15, weight: 650, trackingEm: -0.01)
        /// Stat tiles ("4.1 GB").
        static let stat = TextStyle(family: .display, size: 24, weight: 700, trackingEm: -0.03, tabularNumbers: true)
        /// The percentage inside a 46 pt progress arc.
        static let arcLabel = TextStyle(family: .display, size: 11.5, weight: 700, trackingEm: -0.02,
                                        tabularNumbers: true)
        /// The wordmark ("Goel°").
        static let wordmark = TextStyle(family: .display, size: 18, weight: 750, trackingEm: -0.03)

        // MARK: UI (Figtree)

        /// The omnibox's input and placeholder.
        static let omnibox = TextStyle(family: .ui, size: 16, weight: 500)
        /// The detail sheet's file name.
        static let headline = TextStyle(family: .ui, size: 14.5, weight: 700)
        /// A board card's name.
        static let cardTitle = TextStyle(family: .ui, size: 13.5, weight: 650)
        /// Body copy and list text.
        static let body = TextStyle(family: .ui, size: 13, weight: 400)
        /// Row titles, menu items, emphasised body.
        static let bodyStrong = TextStyle(family: .ui, size: 13, weight: 600)
        /// Button and segmented-control labels.
        static let control = TextStyle(family: .ui, size: 13, weight: 600)
        /// Filter chips, facts lists.
        static let callout = TextStyle(family: .ui, size: 12.5, weight: 600)
        /// Secondary lines, form labels.
        static let small = TextStyle(family: .ui, size: 12, weight: 400)
        /// Card meta lines, help text, pills.
        static let caption = TextStyle(family: .ui, size: 11.5, weight: 400)
        /// The smallest UI text.
        static let tiny = TextStyle(family: .ui, size: 11, weight: 400)
        /// Uppercase section label.
        static let eyebrow = TextStyle(family: .ui, size: 10.5, weight: 700, trackingEm: 0.09, uppercase: true)

        // MARK: Data (Spline Sans Mono)

        /// Speeds, sizes, ETAs on cards and in the status bar.
        static let mono = TextStyle(family: .mono, size: 11.5, weight: 500, tabularNumbers: true)
        /// Counts in chips and lane headers.
        static let monoSmall = TextStyle(family: .mono, size: 11, weight: 500, tabularNumbers: true)
        /// Data inside body text (a path in a facts list).
        static let monoBody = TextStyle(family: .mono, size: 12, weight: 500, tabularNumbers: true)
        /// The omnibox's recognised link and larger read-outs.
        static let monoLarge = TextStyle(family: .mono, size: 14, weight: 500, tabularNumbers: true)
        /// Protocol badges ("HTTP").
        static let badge = TextStyle(family: .mono, size: 10, weight: 600, trackingEm: 0.02)
        /// Key caps ("⌘K").
        static let keyCap = TextStyle(family: .mono, size: 11, weight: 500)

        /// Every named style, for the gallery and tests.
        static let catalog: [(name: String, style: TextStyle)] = [
            ("hero", hero), ("bigNumber", bigNumber), ("title1", title1), ("title2", title2),
            ("title3", title3), ("lane", lane), ("stat", stat), ("arcLabel", arcLabel), ("wordmark", wordmark),
            ("omnibox", omnibox), ("headline", headline), ("cardTitle", cardTitle), ("body", body),
            ("bodyStrong", bodyStrong), ("control", control), ("callout", callout), ("small", small),
            ("caption", caption), ("tiny", tiny), ("eyebrow", eyebrow),
            ("mono", mono), ("monoSmall", monoSmall), ("monoBody", monoBody), ("monoLarge", monoLarge),
            ("badge", badge), ("keyCap", keyCap),
        ]
    }
}

/// The same scaling `.scaledFont(size:)` uses (`@ScaledMetric` relative to `.body`), so Studio text
/// follows the text-size setting.
private struct StudioScaledFont: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var factor: CGFloat = 100

    let style: Studio.TextStyle

    func body(content: Content) -> some View {
        let size = style.size * factor / 100
        let font = StudioFonts.font(style.family, size: size, weight: style.weight,
                                    tabularNumbers: style.tabularNumbers)
        return content
            .font(font)
            .tracking(style.trackingEm * size)
            .textCase(style.uppercase ? .uppercase : nil)
    }
}

extension View {
    /// Applies a Studio text style, scaled with the text-size setting.
    func studioFont(_ style: Studio.TextStyle) -> some View {
        modifier(StudioScaledFont(style: style))
    }

    /// A one-off size or weight in a Studio family, still scaled with the text-size setting.
    func studioFont(_ family: StudioFontFamily, size: CGFloat, weight: CGFloat = 400,
                    tabularNumbers: Bool = false) -> some View {
        modifier(StudioScaledFont(style: Studio.TextStyle(family: family, size: size, weight: weight,
                                                          tabularNumbers: tabularNumbers)))
    }

    /// Mono data with tabular figures: `Text("12 MB/s").studioMono()`.
    func studioMono(size: CGFloat = Studio.TextStyle.mono.size, weight: CGFloat = 500) -> some View {
        studioFont(.mono, size: size, weight: weight, tabularNumbers: true)
    }

    /// Keeps the current family but lines digits up in columns (speeds, counters in Figtree).
    func studioTabularNumbers() -> some View {
        monospacedDigit()
    }
}

/// Scales a layout metric (a row height, an artwork size) by the same factor as Studio text.
struct StudioScaled<Content: View>: View {
    @ScaledMetric(relativeTo: .body) private var factor: CGFloat = 100
    let content: (CGFloat) -> Content

    init(@ViewBuilder _ content: @escaping (_ factor: CGFloat) -> Content) {
        self.content = content
    }

    var body: some View { content(factor / 100) }
}
