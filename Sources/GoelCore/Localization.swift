import Foundation

public enum L10n {

    /// Only `en` and `de` ship real tables; anything added here silently resolves to English.
    public static let supportedLanguages: [(name: String, code: String)] = [
        ("English", "en"),
        ("Deutsch", "de"),
    ]

    public static func languageCode(for language: String) -> String {
        let lower = language.lowercased()
        for entry in supportedLanguages where entry.name.lowercased() == lower || entry.code == lower {
            return entry.code
        }
        switch lower {
        case "german": return "de"
        default: return "en"
        }
    }

    public static func string(_ key: String, language: String) -> String {
        let code = languageCode(for: language)
        if let value = lookup(key, code: code) { return value }
        if code != "en", let value = lookup(key, code: "en") { return value }
        return key
    }

    private static func lprojBundle(_ code: String) -> Bundle? {
        guard let path = ResourceBundles.core?.path(forResource: code, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }

    /// The sentinel default is what distinguishes "missing" from a translation equal to the key.
    private static func lookup(_ key: String, code: String) -> String? {
        guard let bundle = lprojBundle(code) else { return nil }
        let sentinel = "\u{1}__missing__\u{1}"
        let value = bundle.localizedString(forKey: key, value: sentinel, table: nil)
        return value == sentinel ? nil : value
    }
}
