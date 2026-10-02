import Foundation
import GoelCore

/// Locale-aware date and duration text for the GUI. Formatters are cached per locale: the
/// queue formats every row's "Added" column and ETA at the telemetry rate.
enum DisplayFormat {

    /// The app's language, with the user's own region settings (12/24-hour clock, date order)
    /// when the system speaks the same language — `Locale(identifier: "en")` alone would force
    /// a 12-hour clock on a British user.
    static var appLocale: Locale {
        let code = L10n.languageCode(for: L10n.currentLanguage)
        let system = Locale.autoupdatingCurrent
        if system.language.languageCode?.identifier == code { return system }
        return Locale(identifier: code)
    }

    static func duration(_ seconds: TimeInterval, locale: Locale) -> String {
        guard seconds.isFinite, seconds > 0 else { return durationFormatter(locale).string(from: 0) ?? "0s" }
        // Whole seconds only: "1h 30m 0.4s" is noise, and a sub-second ETA reads as "0s".
        let rounded = max(1, seconds.rounded())
        return durationFormatter(locale).string(from: rounded) ?? "\(Int(rounded))s"
    }

    static func relativeDateTime(_ date: Date, locale: Locale) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) || calendar.isDateInYesterday(date) {
            return relativeFormatter(locale).string(from: date)
        }
        return absoluteFormatter(locale).string(from: date)
    }

    /// The list's Added column, one style throughout: "Today 14:03", "Yesterday 14:02", then
    /// "12 Mar" (or "Mar 12"), and the year only once it differs. The tooltip carries the full
    /// ``relativeDateTime``.
    static func compactDateTime(_ date: Date, locale: Locale, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) {
            return L10n.t("Today %@", compactTimeFormatter(locale).string(from: date))
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return L10n.t("Yesterday %@", compactTimeFormatter(locale).string(from: date))
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        return (sameYear ? compactDateFormatter(locale) : compactYearDateFormatter(locale)).string(from: date)
    }

    // MARK: - Cache

    private static let lock = NSLock()
    private static var durationCache: [String: DateComponentsFormatter] = [:]
    private static var relativeCache: [String: DateFormatter] = [:]
    private static var absoluteCache: [String: DateFormatter] = [:]
    private static var compactTimeCache: [String: DateFormatter] = [:]
    private static var compactDateCache: [String: DateFormatter] = [:]
    private static var compactYearDateCache: [String: DateFormatter] = [:]

    private static func cacheKey(_ locale: Locale) -> String {
        // The autoupdating locale's identifier stays the same while its preferences change, so
        // it is keyed separately and rebuilt when the system posts a locale change.
        locale == Locale.autoupdatingCurrent ? "auto:\(locale.identifier)" : locale.identifier
    }

    private static func durationFormatter(_ locale: Locale) -> DateComponentsFormatter {
        cached(&durationCache, key: cacheKey(locale)) {
            let f = DateComponentsFormatter()
            var calendar = Calendar.current
            calendar.locale = locale
            f.calendar = calendar
            f.unitsStyle = .abbreviated
            f.allowedUnits = [.day, .hour, .minute, .second]
            f.maximumUnitCount = 2
            f.zeroFormattingBehavior = .dropAll
            return f
        }
    }

    private static func relativeFormatter(_ locale: Locale) -> DateFormatter {
        cached(&relativeCache, key: cacheKey(locale)) {
            let f = DateFormatter()
            f.locale = locale
            f.dateStyle = .short
            f.timeStyle = .short
            f.doesRelativeDateFormatting = true
            return f
        }
    }

    private static func absoluteFormatter(_ locale: Locale) -> DateFormatter {
        cached(&absoluteCache, key: cacheKey(locale)) {
            let f = DateFormatter()
            f.locale = locale
            // `j` is the locale's preferred hour symbol: 14:03 in Germany and Britain, 2:03 PM in the US.
            f.setLocalizedDateFormatFromTemplate("dMMMjmm")
            return f
        }
    }

    private static func compactTimeFormatter(_ locale: Locale) -> DateFormatter {
        cached(&compactTimeCache, key: cacheKey(locale)) {
            let f = DateFormatter()
            f.locale = locale
            f.dateStyle = .none
            f.timeStyle = .short
            return f
        }
    }

    private static func compactDateFormatter(_ locale: Locale) -> DateFormatter {
        cached(&compactDateCache, key: cacheKey(locale)) {
            let f = DateFormatter()
            f.locale = locale
            f.setLocalizedDateFormatFromTemplate("dMMM")
            return f
        }
    }

    private static func compactYearDateFormatter(_ locale: Locale) -> DateFormatter {
        cached(&compactYearDateCache, key: cacheKey(locale)) {
            let f = DateFormatter()
            f.locale = locale
            f.setLocalizedDateFormatFromTemplate("dMMMyy")
            return f
        }
    }

    private static func cached<F>(_ cache: inout [String: F], key: String, make: () -> F) -> F {
        _ = localeObserver
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        let made = make()
        cache[key] = made
        return made
    }

    /// Drops every cached formatter when the system locale or clock preference changes.
    static func resetCaches() {
        lock.lock()
        durationCache = [:]
        relativeCache = [:]
        absoluteCache = [:]
        compactTimeCache = [:]
        compactDateCache = [:]
        compactYearDateCache = [:]
        lock.unlock()
    }

    private static let localeObserver: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: NSLocale.currentLocaleDidChangeNotification, object: nil, queue: nil
    ) { _ in resetCaches() }
}
