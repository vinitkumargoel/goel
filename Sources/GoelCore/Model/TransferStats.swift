import Foundation

/// Lifetime and per-day transfer accounting, persisted alongside the settings.
/// Fed by the manager from engine progress deltas; rendered by the Statistics
/// window. Days beyond the retention horizon are pruned on write.
public struct TransferStats: Codable, Sendable, Equatable {

    public struct DayTotals: Codable, Sendable, Equatable {
        public var down: Int64
        public var up: Int64
        public init(down: Int64 = 0, up: Int64 = 0) {
            self.down = down
            self.up = up
        }
    }

    public var totalDownloadedBytes: Int64
    public var totalUploadedBytes: Int64
    public var completedCount: Int

    /// Daily totals keyed "yyyy-MM-dd" (local calendar), last ``retentionDays``.
    public var perDay: [String: DayTotals]

    public static let retentionDays = 30

    public init(totalDownloadedBytes: Int64 = 0, totalUploadedBytes: Int64 = 0,
                completedCount: Int = 0, perDay: [String: DayTotals] = [:]) {
        self.totalDownloadedBytes = totalDownloadedBytes
        self.totalUploadedBytes = totalUploadedBytes
        self.completedCount = completedCount
        self.perDay = perDay
    }

    /// Fold a transfer delta into the lifetime and daily buckets.
    public mutating func record(down: Int64, up: Int64, date: Date = Date()) {
        guard down > 0 || up > 0 else { return }
        totalDownloadedBytes += max(0, down)
        totalUploadedBytes += max(0, up)
        let key = Self.dayKey(for: date)
        var day = perDay[key] ?? DayTotals()
        day.down += max(0, down)
        day.up += max(0, up)
        perDay[key] = day
        prune(reference: date)
    }

    /// Today's totals (zero when nothing moved yet).
    public func today(_ date: Date = Date()) -> DayTotals {
        perDay[Self.dayKey(for: date)] ?? DayTotals()
    }

    /// The last `count` days as (dayKey, totals), oldest first, including empty
    /// days — a ready-to-render series for the mini chart.
    public func lastDays(_ count: Int, endingAt date: Date = Date()) -> [(day: String, totals: DayTotals)] {
        let calendar = Calendar.current
        return (0..<count).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: date) else { return nil }
            let key = Self.dayKey(for: day)
            return (key, perDay[key] ?? DayTotals())
        }
    }

    public static func dayKey(for date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private mutating func prune(reference: Date) {
        guard perDay.count > Self.retentionDays,
              let horizon = Calendar.current.date(byAdding: .day, value: -Self.retentionDays,
                                                  to: reference) else { return }
        let cutoff = Self.dayKey(for: horizon)
        perDay = perDay.filter { $0.key >= cutoff }   // keys sort lexically by date
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
