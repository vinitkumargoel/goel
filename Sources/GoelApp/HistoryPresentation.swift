import Foundation
import GoelCore

/// The History window's list: sections by age, a file-type filter and a sort. Pure so the
/// bucketing and the footer can be tested without a window.
enum HistoryPresentation {

    enum Section: Int, CaseIterable, Comparable {
        case today, yesterday, thisWeek, older

        var title: String {
            switch self {
            case .today: return L10n.t("Today")
            case .yesterday: return L10n.t("Yesterday")
            case .thisWeek: return L10n.t("This Week")
            case .older: return L10n.t("Older")
            }
        }

        static func < (a: Section, b: Section) -> Bool { a.rawValue < b.rawValue }

        /// "This week" is the six days before yesterday, not the calendar week: on a Monday the
        /// calendar week would hold nothing but Today.
        static func of(_ date: Date, now: Date, calendar: Calendar = .current) -> Section {
            let today = calendar.startOfDay(for: now)
            let day = calendar.startOfDay(for: date)
            let days = calendar.dateComponents([.day], from: day, to: today).day ?? 0
            switch days {
            case ...0: return .today
            case 1: return .yesterday
            case 2...7: return .thisWeek
            default: return .older
            }
        }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case date, size
        var id: String { rawValue }
        var title: String {
            switch self {
            case .date: return L10n.t("Date")
            case .size: return L10n.t("Size")
            }
        }
    }

    struct Item: Identifiable, Equatable {
        let entry: HistoryEntry
        let type: FileType
        /// Checked once per load: a stat per row per redraw froze the sheet on long histories.
        let exists: Bool
        var id: UUID { entry.id }
    }

    static func items(_ entries: [HistoryEntry], exists: (String) -> Bool) -> [Item] {
        entries.map { entry in
            Item(entry: entry,
                 type: FileType.classify(fileName: entry.name, isTorrent: entry.kind == .torrent),
                 exists: exists(entry.savePath))
        }
    }

    /// The types that actually occur, in the enum's order: a chip for "Disc images" with nothing
    /// behind it is noise.
    static func types(in items: [Item]) -> [FileType] {
        let present = Set(items.map(\.type))
        return FileType.allCases.filter(present.contains)
    }

    static func filtered(_ items: [Item], query: String, type: FileType?) -> [Item] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return items.filter { item in
            (type == nil || item.type == type)
                && (q.isEmpty || item.entry.name.lowercased().contains(q)
                    || item.entry.locator.lowercased().contains(q))
        }
    }

    /// Sections in age order; inside each, newest or largest first. By size the rows still sit
    /// under their age heading, so "the big one from yesterday" stays findable.
    static func sections(_ items: [Item], sort: Sort, now: Date,
                         calendar: Calendar = .current) -> [(section: Section, items: [Item])] {
        let grouped = Dictionary(grouping: items) { Section.of($0.entry.completedAt, now: now, calendar: calendar) }
        return grouped.keys.sorted().map { key in
            let rows = grouped[key] ?? []
            return (key, rows.sorted { order($0, $1, by: sort) })
        }
    }

    private static func order(_ a: Item, _ b: Item, by sort: Sort) -> Bool {
        switch sort {
        case .date:
            return a.entry.completedAt > b.entry.completedAt
        case .size:
            let sa = a.entry.totalBytes ?? -1
            let sb = b.entry.totalBytes ?? -1
            return sa == sb ? a.entry.completedAt > b.entry.completedAt : sa > sb
        }
    }

    /// "12 items · 4.2 GB"; unknown sizes count as items but add no bytes.
    static func footer(_ items: [Item]) -> String {
        let bytes = items.reduce(Int64(0)) { $0 + max(0, $1.entry.totalBytes ?? 0) }
        let count = items.count == 1 ? L10n.t("1 item") : L10n.t("%d items", items.count)
        return bytes > 0 ? L10n.t("%1$@ · %2$@", count, bytes.byteString) : count
    }
}
