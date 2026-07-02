import Foundation

/// The app's localization seam. It resolves a user-facing string for the
/// currently-selected UI language from the bundled `.lproj` tables, falling back
/// to English and finally to the key itself, so a missing translation degrades
/// gracefully instead of showing an empty label.
///
/// The app is only PARTIALLY localized today: this is the working infrastructure
/// plus a real second language (German). Broadening coverage is additive — add
/// keys to each `Localizable.strings` and route more view literals through
/// ``AppSettings`` → `L10n`. Full ~100-language translation remains a dedicated
/// follow-up; nothing here fakes translations that don't exist.
public enum L10n {

    /// Human-readable language names offered in Settings, paired with their code.
    /// Only `en` and `de` ship real tables today; the rest resolve to English
    /// until their tables are added (honest: no empty stubs presented as done).
    public static let supportedLanguages: [(name: String, code: String)] = [
        ("English", "en"),
        ("Deutsch", "de"),
    ]

    /// Map a stored language *name* (as chosen in Settings) to a language code.
    public static func languageCode(for language: String) -> String {
        let lower = language.lowercased()
        for entry in supportedLanguages where entry.name.lowercased() == lower || entry.code == lower {
            return entry.code
        }
        // A few common aliases so an imported/older value still resolves.
        switch lower {
        case "german": return "de"
        default: return "en"
        }
    }

    /// Look up `key` for `language`. Tries the language's table, then English,
    /// then returns `key` unchanged.
    public static func string(_ key: String, language: String) -> String {
        let code = languageCode(for: language)
        if let value = lookup(key, code: code) { return value }
        if code != "en", let value = lookup(key, code: "en") { return value }
        return key
    }

    /// The bundle that carries the `.lproj` resource folders (the SwiftPM-generated
    /// resource bundle for this target).
    private static func lprojBundle(_ code: String) -> Bundle? {
        guard let path = Bundle.module.path(forResource: code, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }

    /// Resolve `key` in the `code` table, or nil when the table/key is absent. A
    /// sentinel default distinguishes "missing" from a translation equal to the key.
    private static func lookup(_ key: String, code: String) -> String? {
        guard let bundle = lprojBundle(code) else { return nil }
        let sentinel = "\u{1}__missing__\u{1}"
        let value = bundle.localizedString(forKey: key, value: sentinel, table: nil)
        return value == sentinel ? nil : value
    }
}
