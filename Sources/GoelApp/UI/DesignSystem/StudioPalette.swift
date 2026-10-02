import SwiftUI
import AppKit

/// The Studio design system's namespace. Tokens live in nested enums (`Studio.Palette`,
/// `Studio.Space`, `Studio.Radius`, `Studio.Elevation`, `Studio.TextStyle`); components are
/// top-level `Studio…` views.
enum Studio {}

/// One token's four resolutions: light, dark, and both under Increase Contrast.
struct StudioColorToken: Sendable {
    let light: OKLCH
    let dark: OKLCH
    let lightHighContrast: OKLCH
    let darkHighContrast: OKLCH

    init(_ light: OKLCH, _ dark: OKLCH, highContrast: (light: OKLCH, dark: OKLCH)? = nil) {
        self.light = light
        self.dark = dark
        self.lightHighContrast = highContrast?.light ?? light
        self.darkHighContrast = highContrast?.dark ?? dark
    }

    func resolve(_ variant: AppearanceVariant) -> OKLCH {
        switch (variant.isDark, variant.isHighContrast) {
        case (false, false): return light
        case (true, false): return dark
        case (false, true): return lightHighContrast
        case (true, true): return darkHighContrast
        }
    }

    func opacity(_ light: Double, _ dark: Double, highContrast: (light: Double, dark: Double)? = nil) -> StudioColorToken {
        StudioColorToken(self.light.opacity(light), self.dark.opacity(dark),
                   highContrast: (lightHighContrast.opacity(highContrast?.light ?? light),
                                  darkHighContrast.opacity(highContrast?.dark ?? dark)))
    }

    /// Resolved from the drawing appearance, so a window's own appearance (set by the Studio
    /// appearance setting or the snapshot harness) wins over the system's.
    var nsColor: NSColor {
        let resolved = (light.nsColor, dark.nsColor, lightHighContrast.nsColor, darkHighContrast.nsColor)
        return NSColor(name: nil) { appearance in
            let variant = AppearanceVariant.resolve(appearance)
            switch (variant.isDark, variant.isHighContrast) {
            case (false, false): return resolved.0
            case (true, false): return resolved.1
            case (false, true): return resolved.2
            case (true, true): return resolved.3
            }
        }
    }

    var color: Color { Color(nsColor: nsColor) }
}

/// A file type's tile colours: a two-stop fill, the glyph drawn on it, and a text tint that
/// reads on the canvas (for a chip or a legend in that type's hue).
struct StudioFileTint {
    let fill: Color
    let fillDeep: Color
    let glyph: Color
    let ink: Color
    let soft: Color
}

extension Studio {

    /// Colour tokens, named after the mockup's CSS variables. Every value is dynamic: it resolves
    /// from the effective appearance of whatever draws it, including Increase Contrast.
    enum Palette {
        // MARK: Surfaces

        /// `--canvas`: the sage-tinted window background.
        static let canvas = Tones.canvas.color
        /// `--canvas-2`: the icon rail, settings sidebar and other recessed chrome.
        static let rail = Tones.rail.color
        /// `--card`: cards, the omnibox, buttons.
        static let card = Tones.card.color
        /// `--card-2`: wells, sheet footers, the status bar, a card inside a card.
        static let well = Tones.well.color
        /// Menus, popovers and anything floating over a card. Lifted above `card` in dark mode.
        static let cardRaised = Tones.cardRaised.color
        /// The floating detail sheet and modal sheets.
        static let sheet = Tones.sheet.color
        /// `--card-edge`: the 1 px rim on cards and sheets.
        static let cardEdge = Tones.cardEdge.color
        /// `--field`: text-field fill.
        static let field = Tones.field.color
        /// `--seg-bg`: segmented-control track, badges, neutral pills.
        static let segment = Tones.segment.color
        /// `--track`: the unfilled part of progress arcs and bars.
        static let track = Tones.track.color

        // MARK: Ink

        /// `--ink`: primary text.
        static let ink = Tones.ink.color
        /// `--ink-2`: secondary text.
        static let ink2 = Tones.ink2.color
        /// `--ink-3`: tertiary text, placeholders, axis labels.
        static let ink3 = Tones.ink3.color

        // MARK: Lines

        /// `--line`: dividers between rows.
        static let hairline = Tones.hairline.color
        /// `--line-2`: control borders, separators that must be seen.
        static let hairlineStrong = Tones.hairlineStrong.color

        // MARK: Accent

        /// `--accent`: deep teal-green.
        static let accent = Tones.accent.color
        /// `--accent-2`: pressed / gradient partner.
        static let accentStrong = Tones.accentStrong.color
        /// `--accent-ink`: text and glyphs on an accent fill.
        static let onAccent = Tones.onAccent.color
        /// `--accent-soft`: selected rows, soft buttons, focus halos.
        static let accentSoft = Tones.accentSoft.color
        /// `--accent-line`: dashed drop zones, focused omnibox rim.
        static let accentLine = Tones.accentLine.color
        /// The keyboard focus ring. Solid accent under Increase Contrast.
        static let focusRing = Tones.focusRing.color

        // MARK: Semantic

        static let good = Tones.good.color
        static let goodSoft = Tones.goodSoft.color
        static let warn = Tones.warn.color
        static let warnSoft = Tones.warnSoft.color
        static let bad = Tones.bad.color
        static let badSoft = Tones.badSoft.color
        static let info = Tones.info.color
        static let infoSoft = Tones.infoSoft.color
        /// `--up`: upload rates and seeding.
        static let upload = Tones.upload.color
        static let uploadSoft = Tones.uploadSoft.color

        // MARK: Overlays

        /// `--scrim`: behind a modal sheet.
        static let scrim = Tones.scrim.color
        /// `--glass`: badges and controls laid over artwork or video.
        static let glass = Tones.glass.color
        /// `--art-hi`: the pattern ink on artwork tiles.
        static let artHighlight = Tones.artHighlight.color
        /// `--art-ink`: the glyph on artwork tiles.
        static let artInk = Tones.artInk.color

        /// Text on `ink` (the dark tooltip, the selected filter chip).
        static let inverseInk = Tones.canvas.color

        static func fileTint(_ kind: StudioArtKind) -> StudioFileTint { Tones.fileTint(kind) }
    }

    /// The raw tones behind ``Palette``, for code that needs an `NSColor` or a resolved value.
    enum Tones {
        private typealias C = OKLCH

        static let canvas = StudioColorToken(C(0.97, 0.008, 150), C(0.22, 0.02, 165))
        static let rail = StudioColorToken(C(0.945, 0.011, 150), C(0.20, 0.019, 165))
        static let card = StudioColorToken(C(1, 0, 0), C(0.275, 0.022, 165))
        static let well = StudioColorToken(C(0.986, 0.005, 150), C(0.255, 0.021, 165))
        static let cardRaised = StudioColorToken(C(1, 0, 0), C(0.31, 0.022, 165))
        static let sheet = StudioColorToken(C(1, 0, 0), C(0.29, 0.022, 165))
        static let cardEdge = StudioColorToken(C(0.92, 0.01, 150), C(0.33, 0.022, 165),
                                         highContrast: (C(0.62, 0.02, 150), C(0.60, 0.02, 165)))
        static let field = StudioColorToken(C(0.988, 0.004, 150), C(0.24, 0.02, 165))
        static let segment = StudioColorToken(C(0.935, 0.011, 150), C(0.245, 0.02, 165),
                                        highContrast: (C(0.90, 0.012, 150), C(0.30, 0.02, 165)))
        static let track = StudioColorToken(C(0.92, 0.012, 150), C(0.35, 0.02, 165),
                                      highContrast: (C(0.78, 0.015, 150), C(0.48, 0.02, 165)))

        static let ink = StudioColorToken(C(0.25, 0.022, 165), C(0.95, 0.01, 160),
                                    highContrast: (C(0.16, 0.02, 165), C(0.99, 0.005, 160)))
        static let ink2 = StudioColorToken(C(0.45, 0.018, 165), C(0.79, 0.016, 160),
                                     highContrast: (C(0.30, 0.02, 165), C(0.90, 0.012, 160)))
        static let ink3 = StudioColorToken(C(0.58, 0.014, 165), C(0.66, 0.016, 160),
                                     highContrast: (C(0.40, 0.018, 165), C(0.82, 0.014, 160)))

        static let hairline = StudioColorToken(C(0.92, 0.01, 150), C(0.32, 0.02, 165),
                                         highContrast: (C(0.62, 0.02, 150), C(0.60, 0.02, 165)))
        static let hairlineStrong = StudioColorToken(C(0.86, 0.013, 150), C(0.39, 0.022, 165),
                                               highContrast: (C(0.50, 0.02, 150), C(0.70, 0.02, 165)))

        static let accent = StudioColorToken(C(0.52, 0.11, 170), C(0.76, 0.12, 170),
                                       highContrast: (C(0.42, 0.10, 170), C(0.84, 0.11, 170)))
        static let accentStrong = StudioColorToken(C(0.45, 0.10, 170), C(0.82, 0.11, 170),
                                             highContrast: (C(0.36, 0.09, 170), C(0.88, 0.10, 170)))
        static let onAccent = StudioColorToken(C(0.99, 0.005, 170), C(0.21, 0.03, 170),
                                         highContrast: (C(1, 0, 0), C(0.14, 0.03, 170)))
        static let accentSoft = accent.opacity(0.11, 0.15, highContrast: (0.20, 0.26))
        static let accentLine = accent.opacity(0.35, 0.45, highContrast: (0.8, 0.8))
        static let focusRing = accent.opacity(0.5, 0.6, highContrast: (1, 1))

        static let good = StudioColorToken(C(0.56, 0.13, 150), C(0.77, 0.14, 150),
                                     highContrast: (C(0.42, 0.12, 150), C(0.86, 0.13, 150)))
        static let goodSoft = good.opacity(0.13, 0.15, highContrast: (0.2, 0.24))
        static let warn = StudioColorToken(C(0.62, 0.14, 65), C(0.82, 0.13, 75),
                                     highContrast: (C(0.48, 0.12, 60), C(0.88, 0.12, 80)))
        static let warnSoft = StudioColorToken(C(0.70, 0.14, 70, alpha: 0.18), C(0.82, 0.13, 75, alpha: 0.16),
                                         highContrast: (C(0.70, 0.14, 70, alpha: 0.28), C(0.82, 0.13, 75, alpha: 0.26)))
        static let bad = StudioColorToken(C(0.55, 0.17, 27), C(0.72, 0.15, 25),
                                    highContrast: (C(0.44, 0.16, 27), C(0.82, 0.13, 25)))
        static let badSoft = bad.opacity(0.11, 0.15, highContrast: (0.2, 0.24))
        static let info = StudioColorToken(C(0.55, 0.12, 255), C(0.78, 0.10, 255),
                                     highContrast: (C(0.44, 0.12, 255), C(0.86, 0.09, 255)))
        static let infoSoft = info.opacity(0.12, 0.15, highContrast: (0.2, 0.24))
        static let upload = StudioColorToken(C(0.55, 0.11, 225), C(0.77, 0.10, 225),
                                       highContrast: (C(0.44, 0.10, 225), C(0.86, 0.09, 225)))
        static let uploadSoft = upload.opacity(0.12, 0.15, highContrast: (0.2, 0.24))

        static let scrim = StudioColorToken(C(0.30, 0.03, 165, alpha: 0.32), C(0.14, 0.02, 165, alpha: 0.5))
        static let glass = StudioColorToken(C(1, 0, 0, alpha: 0.72), C(0.25, 0.02, 165, alpha: 0.7),
                                      highContrast: (C(1, 0, 0, alpha: 0.92), C(0.22, 0.02, 165, alpha: 0.92)))
        static let artHighlight = StudioColorToken(C(1, 0, 0, alpha: 0.26), C(1, 0, 0, alpha: 0.18))
        static let artInk = StudioColorToken(C(0.99, 0.005, 90), C(0.98, 0.005, 90))
        /// The shadow hue; ``Studio/Elevation`` sets the alpha per layer.
        static let shadow = StudioColorToken(C(0.30, 0.03, 165), C(0.10, 0.02, 165))

        // MARK: File types

        /// `(fill, fillDeep)` for light and dark, straight from the mockup's `--t-*` pairs.
        /// Images and Other are not in the mockup: images take a leaf green and Other a quiet sage.
        private static func stops(_ kind: StudioArtKind) -> (light: (C, C), dark: (C, C)) {
            switch kind {
            case .video: return ((C(0.72, 0.13, 32), C(0.60, 0.15, 22)), (C(0.64, 0.12, 32), C(0.50, 0.13, 22)))
            case .audio: return ((C(0.84, 0.13, 85), C(0.72, 0.15, 65)), (C(0.74, 0.12, 85), C(0.60, 0.13, 65)))
            case .disc: return ((C(0.76, 0.08, 300), C(0.62, 0.11, 295)), (C(0.64, 0.08, 300), C(0.50, 0.10, 295)))
            case .archive: return ((C(0.84, 0.05, 75), C(0.70, 0.07, 65)), (C(0.70, 0.05, 75), C(0.56, 0.06, 65)))
            case .app: return ((C(0.78, 0.09, 230), C(0.62, 0.12, 240)), (C(0.66, 0.09, 230), C(0.52, 0.11, 240)))
            case .doc: return ((C(0.68, 0.03, 250), C(0.52, 0.04, 255)), (C(0.58, 0.03, 250), C(0.45, 0.04, 255)))
            case .magnet: return ((C(0.70, 0.12, 350), C(0.58, 0.15, 355)), (C(0.62, 0.12, 350), C(0.50, 0.14, 355)))
            case .folder: return ((C(0.80, 0.07, 170), C(0.62, 0.09, 172)), (C(0.64, 0.07, 170), C(0.50, 0.08, 172)))
            case .image: return ((C(0.80, 0.11, 135), C(0.64, 0.13, 145)), (C(0.68, 0.10, 135), C(0.52, 0.12, 145)))
            case .other: return ((C(0.80, 0.015, 160), C(0.64, 0.02, 165)), (C(0.60, 0.015, 160), C(0.47, 0.02, 165)))
            }
        }

        private static let tintCache: [StudioArtKind: StudioFileTint] = {
            var result: [StudioArtKind: StudioFileTint] = [:]
            for kind in StudioArtKind.allCases {
                let s = stops(kind)
                // Increase Contrast deepens both stops so the white glyph keeps its edge.
                let fill = StudioColorToken(s.light.0, s.dark.0,
                                      highContrast: (s.light.0.lighter(-0.12), s.dark.0.lighter(-0.08)))
                let deep = StudioColorToken(s.light.1, s.dark.1,
                                      highContrast: (s.light.1.lighter(-0.12), s.dark.1.lighter(-0.08)))
                let deepLight = s.light.1
                let baseDark = s.dark.0
                let ink = StudioColorToken(C(0.46, max(deepLight.c, 0.04), deepLight.h), C(0.82, max(baseDark.c, 0.03), baseDark.h),
                                     highContrast: (C(0.36, max(deepLight.c, 0.04), deepLight.h),
                                                    C(0.90, max(baseDark.c, 0.03), baseDark.h)))
                let soft = StudioColorToken(s.light.0.opacity(0.22), s.dark.0.opacity(0.24))
                result[kind] = StudioFileTint(fill: fill.color, fillDeep: deep.color, glyph: artInk.color,
                                              ink: ink.color, soft: soft.color)
            }
            return result
        }()

        static func fileTint(_ kind: StudioArtKind) -> StudioFileTint {
            // The cache covers every case; the fallback only keeps the compiler honest.
            tintCache[kind] ?? StudioFileTint(fill: card.color, fillDeep: card.color, glyph: ink.color,
                                              ink: ink.color, soft: segment.color)
        }
    }
}
