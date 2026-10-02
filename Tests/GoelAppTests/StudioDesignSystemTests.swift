import XCTest
import AppKit
import GoelCore
@testable import GoelApp

final class StudioDesignSystemTests: XCTestCase {

    // MARK: Appearance migration

    func testStoredThemesMigrateToSystemLightOrDark() {
        let expected: [String: StudioAppearanceMode] = [
            "system": .system,
            "light": .light,
            "dark": .dark,
            "frost-light": .light,
            "frost-dark": .dark,
            "dracula": .dark,
            "nord": .dark,
            "aurora-light": .system,
            "": .system,
            "  Frost-Light ": .light,
        ]
        for (stored, mode) in expected {
            XCTAssertEqual(StudioAppearanceMode(storedValue: stored), mode, "stored value \(stored)")
        }
    }

    func testNewStoredValuesRoundTrip() {
        for mode in StudioAppearanceMode.allCases {
            XCTAssertEqual(StudioAppearanceMode(storedValue: mode.storedValue), mode)
        }
    }

    func testRemotePortalThemeKeepsItsOwnTokens() {
        for theme in RemotePortalTheme.allCases {
            XCTAssertEqual(RemotePortalTheme(storedValue: theme.storedValue), theme)
        }
        XCTAssertEqual(RemotePortalTheme.allCases.map(\.storedValue),
                       ["frost-light", "frost-dark", "dracula", "nord"])
        XCTAssertEqual(RemotePortalTheme(storedValue: "light"), .frostLight)
        XCTAssertEqual(RemotePortalTheme(storedValue: "system"), .frostDark)
        XCTAssertEqual(RemotePortalTheme(storedValue: "aurora"), .frostDark)
        XCTAssertEqual(RemotePortalTheme(storedValue: AppSettings().remoteTheme), .frostDark)
    }

    func testToggleFlipsTheLookOnScreen() {
        XCTAssertEqual(StudioAppearanceMode.light.toggled(currentlyDark: false), .dark)
        XCTAssertEqual(StudioAppearanceMode.dark.toggled(currentlyDark: true), .light)
        XCTAssertEqual(StudioAppearanceMode.system.toggled(currentlyDark: true), .light)
        XCTAssertEqual(StudioAppearanceMode.system.toggled(currentlyDark: false), .dark)
        XCTAssertNil(StudioAppearanceMode.system.colorScheme)
        XCTAssertEqual(StudioAppearanceMode.dark.colorScheme, .dark)
    }

    @MainActor
    func testAppAppearancePublishesTheMigratedMode() {
        var settings = AppSettings()
        settings.theme = "dracula"
        let appearance = AppAppearance(settings: settings)
        XCTAssertEqual(appearance.mode, .dark)
        XCTAssertEqual(appearance.colorScheme, .dark)
        settings.theme = "system"
        appearance.apply(settings)
        XCTAssertEqual(appearance.mode, .system)
        XCTAssertNil(appearance.colorScheme)
    }

    func testFreshSettingsFollowTheSystem() {
        XCTAssertEqual(StudioAppearanceMode(storedValue: AppSettings().theme), .system)
    }

    // MARK: Colour

    private func hex(_ color: OKLCH) -> UInt32 {
        let srgb = color.nsColor.usingColorSpace(.sRGB)!
        func channel(_ value: CGFloat) -> UInt32 { UInt32((min(1, max(0, value)) * 255).rounded()) }
        return channel(srgb.redComponent) << 16 | channel(srgb.greenComponent) << 8 | channel(srgb.blueComponent)
    }

    func testOKLCHMatchesTheMockupsComputedColours() {
        // Reference values from the CSS Color 4 OKLCH → sRGB conversion.
        XCTAssertEqual(hex(OKLCH(0.97, 0.008, 150)), 0xF1F7F2, accuracy: 0x010101)
        XCTAssertEqual(hex(OKLCH(0.22, 0.02, 165)), 0x121E18, accuracy: 0x010101)
        XCTAssertEqual(hex(OKLCH(1, 0, 0)), 0xFFFFFF)
        XCTAssertEqual(hex(OKLCH(0, 0, 0)), 0x000000)
    }

    func testTextTokensClearContrastOnTheirSurfaces() {
        let tones = Studio.Tones.self
        let pairs: [(String, StudioColorToken, StudioColorToken, Double)] = [
            ("ink on canvas", tones.ink, tones.canvas, 7),
            ("ink on card", tones.ink, tones.card, 7),
            ("ink2 on card", tones.ink2, tones.card, 4.5),
            ("ink2 on canvas", tones.ink2, tones.canvas, 4.5),
            ("ink3 on card", tones.ink3, tones.card, 3),
            ("onAccent on accent", tones.onAccent, tones.accent, 4.5),
            ("accent on card", tones.accent, tones.card, 3),
            ("bad on card", tones.bad, tones.card, 3),
        ]
        for (name, foreground, background, minimum) in pairs {
            for variant in [AppearanceVariant(isDark: false, isHighContrast: false),
                            AppearanceVariant(isDark: true, isHighContrast: false)] {
                let ratio = WCAG.contrastRatio(hex(foreground.resolve(variant)), hex(background.resolve(variant)))
                XCTAssertGreaterThanOrEqual(ratio, minimum, "\(name), dark: \(variant.isDark)")
            }
        }
    }

    func testIncreaseContrastStrengthensSecondaryInk() {
        let normal = AppearanceVariant(isDark: false, isHighContrast: false)
        let high = AppearanceVariant(isDark: false, isHighContrast: true)
        let tones = Studio.Tones.self
        let before = WCAG.contrastRatio(hex(tones.ink3.resolve(normal)), hex(tones.card.resolve(normal)))
        let after = WCAG.contrastRatio(hex(tones.ink3.resolve(high)), hex(tones.card.resolve(high)))
        XCTAssertGreaterThan(after, before)
        XCTAssertGreaterThanOrEqual(after, 4.5)
    }

    // MARK: Presentation mapping

    func testEveryFileTypeHasArtwork() {
        XCTAssertEqual(StudioArtKind(FileType.iso), .disc)
        for type in FileType.allCases {
            let kind = StudioArtKind(type)
            XCTAssertFalse(kind.accessibilityName.isEmpty)
        }
        XCTAssertNil(StudioArtKind.magnet.symbol, "the magnet glyph is drawn, SF Symbols has none")
    }

    func testDownloadStatesComeFromTheTask() {
        func task(_ status: DownloadStatus, missing: Bool? = nil) -> DownloadTask {
            var task = DownloadTask(source: .url(URL(string: "https://example.com/a.iso")!), name: "a.iso",
                                    saveDirectory: "/tmp", status: status)
            task.fileMissing = missing
            return task
        }
        XCTAssertEqual(StudioDownloadState(task: task(.queued)), .queued)
        XCTAssertEqual(StudioDownloadState(task: task(.requestingMetadata)), .requestingMetadata)
        XCTAssertEqual(StudioDownloadState(task: task(.failed(.timedOut))), .failed)
        XCTAssertEqual(StudioDownloadState(task: task(.completed)), .completed)
        XCTAssertEqual(StudioDownloadState(task: task(.completed, missing: true)), .fileMissing)
        XCTAssertEqual(StudioProgressTone(task: task(.seeding)), .upload)
        XCTAssertEqual(Set(StudioDownloadState.allCases.map(\.title)).count, StudioDownloadState.allCases.count)
    }

    // MARK: Type

    func testTypeCatalogNamesAreUnique() {
        let names = Studio.TextStyle.catalog.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
    }

    func testBundledFontsRegisterWhenTheResourceBundleIsPresent() throws {
        try XCTSkipIf(ResourceBundles.app == nil, "no app resource bundle in this test run")
        let registered = StudioFonts.registerAll()
        for family in StudioFontFamily.allCases {
            XCTAssertEqual(registered[family], true, "\(family.familyName) did not register")
            let regular = try XCTUnwrap(StudioFonts.ctFont(family, size: 13, weight: 400))
            let bold = try XCTUnwrap(StudioFonts.ctFont(family, size: 13, weight: 700))
            XCTAssertEqual(CTFontCopyFamilyName(regular) as String, family.familyName)
            // Different points on the weight axis must give different glyph advances or outlines.
            let w = CTFontCopyVariation(regular) as? [NSNumber: NSNumber]
            let b = CTFontCopyVariation(bold) as? [NSNumber: NSNumber]
            XCTAssertNotEqual(w, b, "\(family.familyName) weight axis ignored")
        }
    }

    #if DEBUG
    @MainActor
    func testSnapshotEntriesHaveUniqueAreaPrefixedNames() {
        let names = StudioSnapshotRegistry.all.map(\.name)
        XCTAssertEqual(Set(names).count, names.count)
        let prefixes = ["ds.", "main.", "downloads.", "detail.", "add.", "settings.", "sftp.", "windows."]
        for name in names {
            XCTAssertTrue(prefixes.contains { name.hasPrefix($0) }, "\(name) has no area prefix")
        }
    }

    @MainActor
    func testSampleModelShowsTheSampleQueueWithoutStarting() {
        let model = StudioSampleData.makeViewModel()
        XCTAssertEqual(model.tasks.count, StudioSampleData.ID.allCases.count)
        XCTAssertFalse(model.isRestoring)
        XCTAssertTrue(model.runningEngineKinds.isEmpty, "the sample model must never start the engine")
        XCTAssertEqual(model.primarySelection, StudioSampleData.ID.ubuntu.uuid)
        let states = Set(model.tasks.map { StudioDownloadState(task: $0) })
        XCTAssertTrue(states.isSuperset(of: [.downloading, .seeding, .requestingMetadata, .paused, .completed, .failed, .queued]))
    }
    #endif
}

private func XCTAssertEqual(_ a: UInt32, _ b: UInt32, accuracy: UInt32, file: StaticString = #filePath, line: UInt = #line) {
    for shift: UInt32 in [16, 8, 0] {
        let x = Int((a >> shift) & 0xFF), y = Int((b >> shift) & 0xFF)
        XCTAssertLessThanOrEqual(abs(x - y), Int(accuracy & 0xFF), String(format: "#%06X vs #%06X", a, b), file: file, line: line)
    }
}
