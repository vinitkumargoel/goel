import Foundation
import GoelCore

struct ScheduledStartOption: Identifiable {
    let id: String
    let label: String
    let date: () -> Date

    static var presets: [ScheduledStartOption] {
        [
            ScheduledStartOption(id: "1h", label: L10n.t("In 1 Hour")) {
                Date().addingTimeInterval(3600)
            },
            ScheduledStartOption(id: "4h", label: L10n.t("In 4 Hours")) {
                Date().addingTimeInterval(4 * 3600)
            },
            ScheduledStartOption(id: "night", label: L10n.t("Tonight at 2 AM")) { Self.next(hour: 2) },
            ScheduledStartOption(id: "morning", label: L10n.t("Tomorrow at 8 AM")) { Self.next(hour: 8) },
        ]
    }

    private static func next(hour: Int) -> Date {
        let calendar = Calendar.current
        let now = Date()
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = hour
        components.minute = 0
        let candidate = calendar.date(from: components) ?? now
        return candidate > now
            ? candidate
            : calendar.date(byAdding: .day, value: 1, to: candidate) ?? now
    }
}
