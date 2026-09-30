import Foundation
import GoelCore

/// What the whole queue adds up to: the detail panel's overview when nothing is selected, and
/// the status bar's "done ≈ 14:32". Pure, so the ETA arithmetic is tested, not trusted.
struct QueueOverview: Equatable {
    var active = 0
    var queued = 0
    var done = 0
    var failed = 0
    var speed = SpeedSample.zero
    /// Bytes still to fetch across downloads that are running or waiting their turn.
    var remainingBytes: Int64 = 0
    /// Some unfinished download has no known size yet, so the ETA is a lower bound.
    var hasUnknownSize = false

    init(tasks: [DownloadTask], speed: (DownloadTask) -> SpeedSample) {
        var down = 0.0, up = 0.0
        for task in tasks {
            let sample = speed(task)
            down += sample.down
            up += sample.up
            switch task.status {
            case .queued: queued += 1
            case .completed, .seeding: done += 1
            case .failed: failed += 1
            default: break
            }
            if task.status.isActive, task.status != .seeding { active += 1 }
            // Paused rows are the user's choice to wait; they don't count toward "done at".
            guard task.status.isActiveWork else { continue }
            if let total = task.totalBytes, total > 0 {
                remainingBytes += max(0, total - task.bytesDownloaded)
            } else {
                hasUnknownSize = true
            }
        }
        self.speed = SpeedSample(down: down, up: up)
    }

    /// Seconds until the queue drains at the current combined rate; nil when idle or finished.
    var eta: TimeInterval? {
        guard remainingBytes > 0, speed.down >= 1 else { return nil }
        return Double(remainingBytes) / speed.down
    }

    func doneAt(now: Date = Date()) -> Date? {
        eta.map { now.addingTimeInterval($0) }
    }

    /// "14:32" today, "Tue 09:10" within the week, a date beyond — in the app's locale.
    static func clockText(_ date: Date, now: Date = Date(), locale: Locale = DisplayFormat.appLocale,
                          calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        let template: String
        if calendar.isDate(date, inSameDayAs: now) {
            template = "jmm"
        } else if date.timeIntervalSince(now) < 6 * 86_400 {
            template = "EEEjmm"
        } else {
            template = "MMMdjmm"
        }
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter.string(from: date)
    }

    /// "done ≈ 14:32", or nil when there is nothing to finish or no rate to measure it by.
    func doneText(now: Date = Date(), locale: Locale = DisplayFormat.appLocale) -> String? {
        guard let at = doneAt(now: now) else { return nil }
        let clock = Self.clockText(at, now: now, locale: locale)
        return hasUnknownSize ? L10n.t("done ≥ %@", clock) : L10n.t("done ≈ %@", clock)
    }
}
