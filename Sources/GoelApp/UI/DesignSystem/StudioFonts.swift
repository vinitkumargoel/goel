import SwiftUI
import AppKit
import CoreText
import GoelCore

/// The three Studio typefaces, shipped as variable TTFs in `Resources/Fonts` (SIL OFL 1.1, see
/// THIRD-PARTY-NOTICES.md) and registered for this process at launch.
///
/// Weights are set on the variable `wght` axis rather than by picking a named instance: the mockup
/// uses in-between weights (650, 750), and `Font.custom("Figtree", …)` resolves to the file's
/// default instance, which for Figtree is Light. Bricolage also gets its optical-size axis set from
/// the point size, which is what the mockup's `font-optical-sizing: auto` does.
enum StudioFontFamily: String, CaseIterable, Sendable {
    /// Bricolage Grotesque: big numbers, titles, lane names.
    case display
    /// Figtree: every label and sentence.
    case ui
    /// Spline Sans Mono: speeds, sizes, hashes, paths.
    case mono

    var familyName: String {
        switch self {
        case .display: return "Bricolage Grotesque"
        case .ui: return "Figtree"
        case .mono: return "Spline Sans Mono"
        }
    }

    var fileName: String {
        switch self {
        case .display: return "BricolageGrotesque-Variable"
        case .ui: return "Figtree-Variable"
        case .mono: return "SplineSansMono-Variable"
        }
    }

    /// The `wght` axis range of the shipped file; requests outside it are clamped.
    var weightRange: ClosedRange<CGFloat> {
        switch self {
        case .display: return 200...800
        case .ui: return 300...900
        case .mono: return 300...700
        }
    }
}

enum StudioFonts {

    private static let wghtAxis = NSNumber(value: 0x7767_6874 as UInt32)  // 'wght'
    private static let opszAxis = NSNumber(value: 0x6F70_737A as UInt32)  // 'opsz'

    private static let lock = NSLock()
    nonisolated(unsafe) private static var baseDescriptors: [StudioFontFamily: CTFontDescriptor] = [:]
    nonisolated(unsafe) private static var didRegister = false
    nonisolated(unsafe) private static var cache: [CacheKey: CTFont] = [:]

    private struct CacheKey: Hashable {
        let family: StudioFontFamily
        let size: CGFloat
        let weight: CGFloat
        let tabular: Bool
    }

    /// Registers the bundled fonts once. Safe to call repeatedly and from any thread. A family that
    /// fails to register (missing bundle, damaged file) falls back to the system font everywhere.
    @discardableResult
    static func registerAll() -> [StudioFontFamily: Bool] {
        lock.lock()
        defer { lock.unlock() }
        if !didRegister {
            didRegister = true
            for family in StudioFontFamily.allCases {
                if let descriptor = register(family) { baseDescriptors[family] = descriptor }
            }
        }
        return Dictionary(uniqueKeysWithValues: StudioFontFamily.allCases.map { ($0, baseDescriptors[$0] != nil) })
    }

    static func isAvailable(_ family: StudioFontFamily) -> Bool {
        registerAll()[family] ?? false
    }

    private static func register(_ family: StudioFontFamily) -> CTFontDescriptor? {
        guard let url = ResourceBundles.app?.url(forResource: family.fileName, withExtension: "ttf")
                ?? ResourceBundles.app?.url(forResource: family.fileName, withExtension: "ttf",
                                            subdirectory: "Fonts") else {
            GoelLog.app.error("Studio font missing from the app bundle", .detail(family.fileName))
            return nil
        }
        var error: Unmanaged<CFError>?
        if !CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            // Already registered (a second registration in the same process) is not a failure.
            let cfError = error?.takeRetainedValue()
            let code = cfError.map { CFErrorGetCode($0) } ?? 0
            if code != CTFontManagerError.alreadyRegistered.rawValue {
                GoelLog.app.error("Couldn't register a Studio font",
                                  .detail("\(family.fileName): \(cfError.map { String(describing: $0) } ?? "unknown")"))
                return nil
            }
        }
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first else { return nil }
        return first
    }

    /// A Core Text font for `family` at `size` points and a CSS-style numeric `weight` (100…900).
    /// Returns nil when the family isn't registered; callers fall back to the system font.
    static func ctFont(_ family: StudioFontFamily, size: CGFloat, weight: CGFloat,
                       tabularNumbers: Bool = false) -> CTFont? {
        registerAll()
        let key = CacheKey(family: family, size: (size * 4).rounded() / 4, weight: weight.rounded(),
                           tabular: tabularNumbers)
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        guard let base = baseDescriptors[family] else { return nil }
        var variation: [NSNumber: NSNumber] = [
            wghtAxis: NSNumber(value: Double(min(max(weight, family.weightRange.lowerBound),
                                                 family.weightRange.upperBound))),
        ]
        if family == .display {
            variation[opszAxis] = NSNumber(value: Double(min(max(key.size, 12), 96)))
        }
        var attributes: [CFString: Any] = [kCTFontVariationAttribute: variation]
        if tabularNumbers {
            attributes[kCTFontFeatureSettingsAttribute] = [[
                kCTFontOpenTypeFeatureTag: "tnum",
                kCTFontOpenTypeFeatureValue: 1,
            ]]
        }
        let descriptor = CTFontDescriptorCreateCopyWithAttributes(base, attributes as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, key.size, nil)
        cache[key] = font
        return font
    }

    /// A SwiftUI font, or the matching system font when the family couldn't be registered.
    /// Prefer the `.studioFont(_:)` modifier in views: it also applies the text-size setting.
    static func font(_ family: StudioFontFamily, size: CGFloat, weight: CGFloat, tabularNumbers: Bool = false) -> Font {
        if let ct = ctFont(family, size: size, weight: weight, tabularNumbers: tabularNumbers) {
            return Font(ct)
        }
        let system = Font.system(size: size, weight: Self.systemWeight(weight),
                                 design: family == .mono ? .monospaced : .default)
        return tabularNumbers ? system.monospacedDigit() : system
    }

    /// For AppKit-backed controls (an `NSTextField` omnibox, an attributed string).
    static func nsFont(_ family: StudioFontFamily, size: CGFloat, weight: CGFloat,
                       tabularNumbers: Bool = false) -> NSFont {
        if let ct = ctFont(family, size: size, weight: weight, tabularNumbers: tabularNumbers) {
            return ct as NSFont
        }
        if family == .mono {
            return NSFont.monospacedSystemFont(ofSize: size, weight: nsWeight(weight))
        }
        return NSFont.systemFont(ofSize: size, weight: nsWeight(weight))
    }

    static func systemWeight(_ weight: CGFloat) -> Font.Weight {
        switch weight {
        case ..<250: return .thin
        case ..<350: return .light
        case ..<450: return .regular
        case ..<550: return .medium
        case ..<680: return .semibold
        case ..<780: return .bold
        case ..<880: return .heavy
        default: return .black
        }
    }

    private static func nsWeight(_ weight: CGFloat) -> NSFont.Weight {
        switch systemWeight(weight) {
        case .thin: return .thin
        case .light: return .light
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        default: return .regular
        }
    }
}
