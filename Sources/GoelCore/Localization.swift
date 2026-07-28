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

    /// Ambient language, mirroring `ThemePalette.current`. Views deep in the tree have no
    /// `AppViewModel` to ask, and a `Text` initializer cannot await one.
    public static var currentLanguage: String {
        get {
            languageLock.lock()
            defer { languageLock.unlock() }
            return storedLanguage
        }
        set {
            languageLock.lock()
            defer { languageLock.unlock() }
            storedLanguage = newValue
        }
    }

    /// Looks `key` up in the ambient language. `key` is the English text, so an absent
    /// entry renders as English rather than as a placeholder.
    public static func t(_ key: String) -> String {
        string(key, language: currentLanguage)
    }

    /// For keys carrying `printf` placeholders, so a translation can reorder them with `%1$@`.
    public static func t(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: string(key, language: currentLanguage), arguments: arguments)
    }

    private static let languageLock = NSLock()
    private static var storedLanguage = "English"

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
