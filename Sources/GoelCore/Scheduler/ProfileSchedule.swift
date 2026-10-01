import Foundation

/// The weekly queue-profile grid: 7 days × 24 hours, Sunday 00:00 first (Calendar's weekday 1).
public enum ProfileSchedule {
    public static let slotCount = 7 * 24

    /// 0…167 for `date` in `calendar`.
    public static func slot(for date: Date, calendar: Calendar = .current) -> Int {
        let weekday = calendar.component(.weekday, from: date)   // 1 = Sunday
        let hour = calendar.component(.hour, from: date)
        return (weekday - 1) * 24 + hour
    }

    /// The profile painted into `slot`, or nil when the hour is left alone (or the grid is short).
    public static func profile(at slot: Int, in grid: [String]) -> String? {
        guard grid.indices.contains(slot) else { return nil }
        let name = grid[slot].trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Always `slotCount` long, so the editor can index any cell.
    public static func normalized(_ grid: [String]) -> [String] {
        if grid.count == slotCount { return grid }
        if grid.count > slotCount { return Array(grid.prefix(slotCount)) }
        return grid + Array(repeating: "", count: slotCount - grid.count)
    }

    /// Paints `profile` ("" erases) over the cells from `start` to `end` inclusive — a drag's rectangle.
    public static func painting(_ grid: [String], from start: (day: Int, hour: Int),
                                to end: (day: Int, hour: Int), with profile: String) -> [String] {
        var out = normalized(grid)
        let days = min(start.day, end.day)...max(start.day, end.day)
        let hours = min(start.hour, end.hour)...max(start.hour, end.hour)
        for day in days where (0..<7).contains(day) {
            for hour in hours where (0..<24).contains(hour) {
                out[day * 24 + hour] = profile
            }
        }
        return out
    }

    /// Drops cells naming a profile that no longer exists, so a deleted profile can't be "activated".
    public static func pruned(_ grid: [String], keeping names: Set<String>) -> [String] {
        normalized(grid).map { names.contains($0) ? $0 : "" }
    }
}
