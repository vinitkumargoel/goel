import SwiftUI
import AppKit

extension Studio {

    /// Spacing on a 2 pt grid, named by size. The mockup's recurring gaps are 4, 6, 8, 10, 12, 14,
    /// 16, 18 and 22.
    enum Space {
        static let hair: CGFloat = 2
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 6
        static let s: CGFloat = 8
        static let sm: CGFloat = 10
        static let m: CGFloat = 12
        static let ml: CGFloat = 14
        static let l: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 28
        static let xxxl: CGFloat = 32

        /// Between a glyph and its label, between stacked captions.
        static let snug: CGFloat = 5
        /// Row padding, compact stacks.
        static let cozy: CGFloat = 7
        /// Chip and pill inner padding.
        static let roomy: CGFloat = 9
        /// Between a row's leading art and its text.
        static let relaxed: CGFloat = 11
        /// Settings card and sheet horizontal padding, lane inset.
        static let section: CGFloat = 18

        /// Between board lanes.
        static let laneGap: CGFloat = 18
        /// Between cards in a lane.
        static let cardGap: CGFloat = 10
        /// The main column's padding (`.main { padding: 18px 22px }`).
        static let gutter: CGFloat = 22
    }

    enum Radius {
        /// Swatches and tiny progress bars.
        static let hair: CGFloat = 3
        /// Small tiles and map cells.
        static let micro: CGFloat = 4
        /// Key-cap-sized tiles and focus rims on compact rows.
        static let mini: CGFloat = 5
        /// Badges and key caps.
        static let badge: CGFloat = 6
        /// Small buttons, small fields, menu items.
        static let small: CGFloat = 8
        /// Artwork S tile.
        static let artSmall: CGFloat = 9
        /// Buttons, text fields, icon buttons.
        static let control: CGFloat = 10
        /// Segmented-control track.
        static let segment: CGFloat = 11
        /// Wells, notes.
        static let well: CGFloat = 12
        /// Rail items, artwork M tile, menus.
        static let tile: CGFloat = 13
        /// Compact cards (`.mcard`).
        static let compactCard: CGFloat = 15
        /// Cards, setting groups, toasts.
        static let card: CGFloat = 16
        /// Board cards with an artwork band.
        static let boardCard: CGFloat = 18
        /// Artwork L tile.
        static let artLarge: CGFloat = 18
        /// The omnibox.
        static let omnibox: CGFloat = 20
        /// Sheets and the floating detail sheet.
        static let sheet: CGFloat = 22
    }

    /// Soft layered elevation: 0 flat, 1 a hairline lift (buttons), 2 a resting card, 3 a floating
    /// sheet or popover. Each level stacks two or three shadows like the mockup's `--sh-*`.
    enum Elevation: Int, CaseIterable, Sendable {
        case flat = 0
        case raised = 1
        case card = 2
        case floating = 3

        struct Layer {
            let alphaLight: Double
            let alphaDark: Double
            let radius: CGFloat
            let y: CGFloat
        }

        /// CSS blur radius halves into SwiftUI's; negative CSS spread is folded into a smaller radius.
        var layers: [Layer] {
            switch self {
            case .flat:
                return []
            case .raised:
                return [Layer(alphaLight: 0.06, alphaDark: 0.30, radius: 1, y: 1)]
            case .card:
                return [Layer(alphaLight: 0.04, alphaDark: 0.25, radius: 1, y: 1),
                        Layer(alphaLight: 0.04, alphaDark: 0.25, radius: 2, y: 2),
                        Layer(alphaLight: 0.10, alphaDark: 0.45, radius: 6, y: 6)]
            case .floating:
                return [Layer(alphaLight: 0.06, alphaDark: 0.30, radius: 1, y: 1),
                        Layer(alphaLight: 0.16, alphaDark: 0.50, radius: 11, y: 12),
                        Layer(alphaLight: 0.22, alphaDark: 0.60, radius: 22, y: 28)]
            }
        }

        /// Dark cards also carry a 1 px inner top highlight (`0 1px 0 rgb(255 255 255 / 4%) inset`).
        var darkTopHighlight: Double {
            switch self {
            case .flat, .raised: return 0
            case .card: return 0.04
            case .floating: return 0.05
            }
        }
    }

    enum Motion {
        /// The progress sweep-in (`cubic-bezier(0.2, 0.7, 0.2, 1)` over 1.2 s).
        static let sweep = Animation.timingCurve(0.2, 0.7, 0.2, 1, duration: 1.2)
        /// Hover and press feedback.
        static let quick = Animation.easeOut(duration: 0.12)
        /// Sheets, toasts and lane changes.
        static let spring = Animation.spring(response: 0.32, dampingFraction: 0.86)
    }
}

private struct StudioShadowLayers: ViewModifier {
    let elevation: Studio.Elevation

    func body(content: Content) -> some View {
        let layers = elevation.layers
        let colors = Self.colors[elevation.rawValue]
        content
            .shadow(color: layers.count > 0 ? colors[0] : .clear,
                    radius: layers.count > 0 ? layers[0].radius : 0, x: 0, y: layers.count > 0 ? layers[0].y : 0)
            .shadow(color: layers.count > 1 ? colors[1] : .clear,
                    radius: layers.count > 1 ? layers[1].radius : 0, x: 0, y: layers.count > 1 ? layers[1].y : 0)
            .shadow(color: layers.count > 2 ? colors[2] : .clear,
                    radius: layers.count > 2 ? layers[2].radius : 0, x: 0, y: layers.count > 2 ? layers[2].y : 0)
    }

    /// Built once: a fresh dynamic colour per body pass would defeat SwiftUI's diffing.
    private static let colors: [[Color]] = Studio.Elevation.allCases.map { $0.layers.map(shadowColor) }

    private static func shadowColor(_ layer: Studio.Elevation.Layer) -> Color {
        let tone = Studio.Tones.shadow
        let light = tone.light.opacity(layer.alphaLight).nsColor
        let dark = tone.dark.opacity(layer.alphaDark).nsColor
        return Color(nsColor: NSColor(name: nil) { appearance in
            AppearanceVariant.isDark(appearance) ? dark : light
        })
    }
}

extension View {
    /// Layered Studio shadow. Apply it to a filled background shape, not to text, so the shadow
    /// follows the card's outline instead of every glyph.
    func studioElevation(_ elevation: Studio.Elevation) -> some View {
        modifier(StudioShadowLayers(elevation: elevation))
    }
}

/// Snapshots and Reduce Motion both ask for still frames: no sweep-in, no spinning, no sliding.
private struct StudioStillFramesKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set by the snapshot harness so animated components render a representative still frame.
    var studioStillFrames: Bool {
        get { self[StudioStillFramesKey.self] }
        set { self[StudioStillFramesKey.self] = newValue }
    }
}
