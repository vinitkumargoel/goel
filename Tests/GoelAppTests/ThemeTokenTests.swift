import XCTest
import AppKit
@testable import GoelApp

final class ThemeTokenTests: XCTestCase {

    // MARK: File-type icon fills

    func testEveryFileTypeGlyphClearsAAInEveryTheme() {
        for theme in AppTheme.allCases {
            for type in FileType.allCases {
                let pair = type.fillToken(in: theme)
                for (appearance, base) in [("light", pair.light), ("dark", pair.dark)] {
                    let stops = IconFill.stops(for: base)
                    let top = WCAG.contrastRatio(stops.ink, stops.top)
                    let bottom = WCAG.contrastRatio(stops.ink, stops.bottom)
                    let place = "\(type) in \(theme.rawValue) (\(appearance))"
                    XCTAssertGreaterThanOrEqual(top, IconFill.minimumContrast, "top stop, \(place)")
                    XCTAssertGreaterThanOrEqual(bottom, IconFill.minimumContrast, "bottom stop, \(place)")
                }
            }
        }
    }

    func testFileTypeFillsComeFromThemeTokens() {
        for theme in AppTheme.allCases {
            let colors = theme.colors
            XCTAssertEqual(FileType.iso.fillToken(in: theme), colors.orange)
            XCTAssertEqual(FileType.video.fillToken(in: theme), colors.purple)
            XCTAssertEqual(FileType.archive.fillToken(in: theme), colors.teal)
            XCTAssertEqual(FileType.app.fillToken(in: theme), colors.green)
            XCTAssertEqual(FileType.magnet.fillToken(in: theme), colors.red)
            XCTAssertEqual(FileType.doc.fillToken(in: theme), IconFill.neutral)
        }
    }

    func testStopsLeaveAPassingFillUntouched() {
        // Frost Light accent already clears 4.5:1 against white ink.
        let stops = IconFill.stops(for: 0x3F58D6)
        XCTAssertEqual(stops.top, 0x3F58D6)
        XCTAssertEqual(stops.ink, 0xFFFFFF)
    }

    func testStopsShiftAFailingFillAwayFromItsInk() {
        // Frost Dark light-mode green measures 4.44:1 as published.
        let base: UInt32 = 0x158A3C
        XCTAssertLessThan(WCAG.contrastRatio(WCAG.ink(on: base), base), IconFill.minimumContrast)
        let stops = IconFill.stops(for: base)
        XCTAssertNotEqual(stops.top, base)
        XCTAssertGreaterThanOrEqual(WCAG.contrastRatio(stops.ink, stops.top), IconFill.minimumContrast)
    }

    func testMixEndpoints() {
        XCTAssertEqual(WCAG.mix(0x102030, 0xFFFFFF, 0), 0x102030)
        XCTAssertEqual(WCAG.mix(0x102030, 0xFFFFFF, 1), 0xFFFFFF)
        XCTAssertEqual(WCAG.mix(0x000000, 0xFFFFFF, 0.5), 0x808080)
    }

    // MARK: Appearance resolution

    func testAppearanceVariantResolvesHighContrast() {
        XCTAssertEqual(AppearanceVariant(.aqua), AppearanceVariant(isDark: false, isHighContrast: false))
        XCTAssertEqual(AppearanceVariant(.darkAqua), AppearanceVariant(isDark: true, isHighContrast: false))
        XCTAssertEqual(AppearanceVariant(.accessibilityHighContrastAqua),
                       AppearanceVariant(isDark: false, isHighContrast: true))
        XCTAssertEqual(AppearanceVariant(.accessibilityHighContrastDarkAqua),
                       AppearanceVariant(isDark: true, isHighContrast: true))
    }

    func testHairlineIsStrongerUnderIncreasedContrast() {
        let normal = AppearanceVariant(.aqua)
        let high = AppearanceVariant(.accessibilityHighContrastAqua)
        XCTAssertGreaterThan(Theme.hairlineAlpha(high), Theme.hairlineAlpha(normal))
        XCTAssertGreaterThan(Theme.rowAltAlpha(high), Theme.rowAltAlpha(normal))
    }

    // MARK: File tile cache

    func testTheTileCacheMatchesAFreshComputationForEveryTypeAndTheme() {
        for theme in AppTheme.allCases {
            for type in FileType.allCases {
                let pair = type.fillToken(in: theme)
                let cached = FileTileCache.tile(for: type, theme: theme).stops
                let light = IconFill.stops(for: pair.light), dark = IconFill.stops(for: pair.dark)
                XCTAssertTrue(cached.light == light, "\(type) light in \(theme.rawValue)")
                XCTAssertTrue(cached.dark == dark, "\(type) dark in \(theme.rawValue)")
                XCTAssertEqual(FileTileCache.tile(for: type, theme: theme).gradient.count, 2)
            }
        }
    }

    func testTheTileCacheComputesEachPairOnce() {
        _ = FileTileCache.tile(for: .archive, theme: .nord)
        let before = FileTileCache.computeCount
        for _ in 0..<50 {
            _ = FileTileCache.tile(for: .archive, theme: .nord)
        }
        XCTAssertEqual(FileTileCache.computeCount, before, "repeat lookups hit the cache")
    }

    func testTheTileCacheKeysOnTheTheme() {
        // Frost Light's and Dracula's orange differ, so the iso tile must too.
        XCTAssertFalse(FileTileCache.tile(for: .iso, theme: .frostLight).stops
                       == FileTileCache.tile(for: .iso, theme: .dracula).stops)
    }

    func testTheDarkFastPathAgreesWithTheFullResolve() {
        for name in AppearanceVariant.candidates {
            let appearance = try! XCTUnwrap(NSAppearance(named: name))
            XCTAssertEqual(AppearanceVariant.isDark(appearance), AppearanceVariant.resolve(appearance).isDark,
                           name.rawValue)
        }
    }
}
