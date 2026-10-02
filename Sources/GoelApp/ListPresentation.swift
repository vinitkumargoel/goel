import Foundation
import GoelCore

enum ListPresentation {

    static func visible(
        tasks: [DownloadTask],
        filter: SidebarFilter,
        search: String,
        sortKey: SortKey,
        ascending: Bool
    ) -> [DownloadTask] {
        visible(tasks: tasks, filters: DownloadFilters().setting(filter), search: search,
                sortKey: sortKey, ascending: ascending)
    }

    /// Every axis of `filters` must match (status AND type AND tag), then the search.
    static func visible(
        tasks: [DownloadTask],
        filters: DownloadFilters,
        search: String,
        sortKey: SortKey,
        ascending: Bool
    ) -> [DownloadTask] {
        let rest = DownloadFilters(type: filters.type, tag: filters.tag)
        let coreStatus = isCoreStatus(filters.status)
        let extra: ((DownloadTask) -> Bool)?
        if coreStatus {
            extra = rest.isEmpty ? nil : { rest.matches($0) }
        } else {
            extra = { filters.matches($0) }
        }
        return TaskListQuery.visible(
            tasks: tasks,
            filter: coreStatus ? mapFilter(filters.status) : .all,
            search: search,
            sortKey: mapSort(sortKey),
            ascending: ascending,
            extraMatch: extra
        )
    }

    static func count(tasks: [DownloadTask], filters: DownloadFilters) -> Int {
        filters.isEmpty ? tasks.count : tasks.reduce(0) { $0 + (filters.matches($1) ? 1 : 0) }
    }

    /// Statuses `TaskListQuery` filters itself; the rest are matched app-side.
    private static func isCoreStatus(_ filter: SidebarFilter) -> Bool {
        switch filter {
        case .all, .active, .paused, .completed, .seeding: return true
        case .type, .failed, .queued, .tag: return false
        }
    }

    static func matches(_ task: DownloadTask, filter: SidebarFilter) -> Bool {
        switch filter {
        case .type(let t): return task.fileType == t
        case .failed: return task.status.isFailed
        case .queued: return task.status == .queued
        case .tag(let name): return task.allTags.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
        default: return TaskListQuery.matches(task, filter: mapFilter(filter))
        }
    }

    static func compare(_ a: DownloadTask, _ b: DownloadTask, key: SortKey, ascending: Bool) -> Bool {
        TaskListQuery.compare(a, b, key: mapSort(key), ascending: ascending)
    }

    static func statusOrder(_ s: DownloadStatus) -> Int {
        TaskListQuery.statusOrder(s)
    }

    static func count(tasks: [DownloadTask], filter: SidebarFilter) -> Int {
        switch filter {
        case .type, .failed, .queued, .tag: return tasks.filter { matches($0, filter: filter) }.count
        default: return TaskListQuery.count(tasks: tasks, filter: mapFilter(filter))
        }
    }

    private static func mapFilter(_ filter: SidebarFilter) -> TaskListQuery.Filter {
        switch filter {
        case .all: return .all
        case .active: return .active
        case .paused: return .paused
        case .completed: return .completed
        case .seeding: return .seeding
        case .type, .failed, .queued, .tag: return .all
        }
    }


    private static func mapSort(_ key: SortKey) -> TaskListQuery.SortKey {
        switch key {
        case .index: return .index
        case .name: return .name
        case .size: return .size
        case .status: return .status
        case .added: return .added
        case .downloadSpeed: return .downloadSpeed
        case .uploadSpeed: return .uploadSpeed
        }
    }
}

/// How the list splits into sections. The raw value is the stored preference.
enum ListGrouping: String, CaseIterable, Identifiable {
    case none, date, status, type

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return L10n.t("None")
        case .date: return L10n.t("Date Added")
        case .status: return L10n.t("Status")
        case .type: return L10n.t("Type")
        }
    }
}

/// One run of rows under a sticky header. `id` is stable per bucket, so SwiftUI keeps the header
/// identity while rows move between sections.
struct ListSection: Equatable, Identifiable {
    let id: String
    let title: String
    let tasks: [DownloadTask]

    /// Known sizes only: a magnet still resolving adds nothing rather than a guess.
    var totalBytes: Int64 { tasks.reduce(0) { $0 + ($1.totalBytes ?? 0) } }
}

/// Buckets by `addedAt`, relative to "now" in the user's calendar (its first weekday included).
enum DateBucket: Int, CaseIterable {
    case today, yesterday, thisWeek, thisMonth, older

    var title: String {
        switch self {
        case .today: return L10n.t("Today")
        case .yesterday: return L10n.t("Yesterday")
        case .thisWeek: return L10n.t("Earlier this week")
        case .thisMonth: return L10n.t("Earlier this month")
        case .older: return L10n.t("Older")
        }
    }

    /// A date in the future (a clock that moved back) counts as today rather than vanishing.
    static func bucket(for date: Date, now: Date, calendar: Calendar) -> DateBucket {
        let startOfToday = calendar.startOfDay(for: now)
        if date >= startOfToday { return .today }
        if let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday),
           date >= startOfYesterday { return .yesterday }
        if let week = calendar.dateInterval(of: .weekOfYear, for: now), date >= week.start { return .thisWeek }
        if let month = calendar.dateInterval(of: .month, for: now), date >= month.start { return .thisMonth }
        return .older
    }
}

/// Group by Status: what is moving first, what is finished last.
enum StatusBucket: Int, CaseIterable {
    case active, seeding, queued, paused, failed, completed

    init(_ status: DownloadStatus) {
        switch status {
        case .downloading, .verifying, .requestingMetadata: self = .active
        case .seeding: self = .seeding
        case .queued: self = .queued
        case .paused: self = .paused
        case .failed: self = .failed
        case .completed: self = .completed
        }
    }

    var title: String {
        switch self {
        case .active: return L10n.t("Active")
        case .seeding: return L10n.t("Seeding")
        case .queued: return L10n.t("Queued")
        case .paused: return L10n.t("Paused")
        case .failed: return L10n.t("Failed")
        case .completed: return L10n.t("Completed")
        }
    }
}

extension ListPresentation {

    /// Splits an already sorted list into sections in a fixed bucket order, keeping the sort
    /// inside each section. Empty buckets are left out; `.none` is one untitled section.
    static func sections(
        _ sorted: [DownloadTask],
        by grouping: ListGrouping,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [ListSection] {
        switch grouping {
        case .none:
            return sorted.isEmpty ? [] : [ListSection(id: "all", title: "", tasks: sorted)]
        case .date:
            return bucketed(sorted, order: DateBucket.allCases, id: { "date.\($0.rawValue)" }, title: \.title) {
                DateBucket.bucket(for: $0.addedAt, now: now, calendar: calendar)
            }
        case .status:
            return bucketed(sorted, order: StatusBucket.allCases, id: { "status.\($0.rawValue)" }, title: \.title) {
                StatusBucket($0.status)
            }
        case .type:
            return bucketed(sorted, order: FileType.allCases, id: { "type.\($0.rawValue)" },
                            title: \.accessibilityName) { $0.fileType }
        }
    }

    private static func bucketed<Bucket: Hashable>(
        _ sorted: [DownloadTask],
        order: [Bucket],
        id: (Bucket) -> String,
        title: KeyPath<Bucket, String>,
        bucket: (DownloadTask) -> Bucket
    ) -> [ListSection] {
        let grouped = Dictionary(grouping: sorted, by: bucket)
        return order.compactMap { key in
            guard let rows = grouped[key], !rows.isEmpty else { return nil }
            return ListSection(id: id(key), title: key[keyPath: title], tasks: rows)
        }
    }

    /// Every tag in use with how many rows carry it, alphabetical. Tags differing only in case are
    /// one tag (the first spelling seen wins), matching how ``matches(_:filter:)`` compares them.
    static func tagCounts(_ tasks: [DownloadTask]) -> [(tag: String, count: Int)] {
        var spelling: [String: String] = [:]
        var counts: [String: Int] = [:]
        for task in tasks {
            for tag in task.allTags {
                let key = tag.lowercased()
                if spelling[key] == nil { spelling[key] = tag }
                counts[key, default: 0] += 1
            }
        }
        return counts.keys
            .map { (tag: spelling[$0] ?? $0, count: counts[$0] ?? 0) }
            .sorted { $0.tag.localizedCaseInsensitiveCompare($1.tag) == .orderedAscending }
    }

    /// A tag's colour slot, stable across launches and machines. Not `hashValue`: Swift seeds it
    /// per process, so the dot would change colour every launch.
    static func tagColorSlot(_ tag: String, slots: Int) -> Int {
        guard slots > 0 else { return 0 }
        var hash: UInt32 = 2_166_136_261   // FNV-1a
        for byte in tag.lowercased().utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return Int(hash % UInt32(slots))
    }
}
