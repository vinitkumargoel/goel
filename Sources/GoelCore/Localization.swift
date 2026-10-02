import Foundation

public enum L10n {

    /// The languages offered to users. A language joins only once its table covers at least 95% of
    /// the base strings — CI runs `Scripts/extract-l10n-keys.py --coverage-supported` against this
    /// list — because a mostly-English UI labelled "Deutsch" is worse than an honest English one.
    public static let supportedLanguages: [(name: String, code: String)] = [
        ("English", "en"),
    ]

    /// Every language that ships a table in Resources/, offered or not. German (`de`) is here but
    /// not in ``supportedLanguages`` until its coverage reaches the bar; see
    /// `python3 Scripts/extract-l10n-keys.py --coverage de`.
    static let translatedLanguages: [(name: String, code: String)] = [
        ("English", "en"),
        ("Deutsch", "de"),
    ]

    /// A stored choice of a language that is not (or no longer) offered — someone who picked
    /// "Deutsch" before it was withdrawn — resolves to English rather than a half-translated UI.
    public static func languageCode(for language: String) -> String {
        let code = tableCode(for: language)
        return supportedLanguages.contains { $0.code == code } ? code : "en"
    }

    /// The table a language name or code would use, ignoring whether it is offered.
    static func tableCode(for language: String) -> String {
        let lower = language.lowercased()
        for entry in translatedLanguages where entry.name.lowercased() == lower || entry.code == lower {
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

    /// Ambient language. Views deep in the tree have no
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

    /// Lowercases a translated fragment being dropped into the middle of a sentence — "Cancel
    /// download", not "Cancel Download". German capitalizes every noun, so doing this
    /// unconditionally would produce "Warten auf konvertierung"; there it is left alone.
    public static func midSentence(_ value: String) -> String {
        languagesCapitalizingNouns.contains(languageCode(for: currentLanguage))
            ? value : value.lowercased()
    }

    private static let languagesCapitalizingNouns: Set<String> = ["de"]

    private static let languageLock = NSLock()
    private static var storedLanguage = "English"

    private static func lprojBundle(_ code: String) -> Bundle? {
        guard let path = ResourceBundles.core?.path(forResource: code, ofType: "lproj") else { return nil }
        return Bundle(path: path)
    }

    /// The sentinel default is what distinguishes "missing" from a translation equal to the key.
    static func lookup(_ key: String, code: String) -> String? {
        guard let bundle = lprojBundle(code) else { return nil }
        let sentinel = "\u{1}__missing__\u{1}"
        let value = bundle.localizedString(forKey: key, value: sentinel, table: nil)
        return value == sentinel ? nil : value
    }
}
