import Foundation
import GoelCore

/// Pure filter/search/sort over the download task list. AppViewModel owns the
/// inputs; this owns the derivation so list presentation stays free of UI state.
enum ListPresentation {

    static func visible(
        tasks: [DownloadTask],
        filter: SidebarFilter,
        search: String,
        sortKey: SortKey,
        ascending: Bool
    ) -> [DownloadTask] {
        var list = tasks.filter { matches($0, filter: filter) }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter { task in
                task.name.lowercased().contains(q)
                    || task.allTags.contains { $0.lowercased().contains(q) }
                    || (task.note?.lowercased().contains(q) ?? false)
            }
        }
        return list.sorted { compare($0, $1, key: sortKey, ascending: ascending) }
    }

    static func matches(_ task: DownloadTask, filter: SidebarFilter) -> Bool {
        switch filter {
        case .all: return true
        case .active: return task.status.isActive
        case .paused: return task.status == .paused
        case .completed: return task.status == .completed
        case .seeding: return task.status == .seeding
        case .type(let t): return task.fileType == t
        }
    }

    static func compare(_ a: DownloadTask, _ b: DownloadTask, key: SortKey, ascending: Bool) -> Bool {
        let result: Bool
        switch key {
        case .index, .added:
            result = a.addedAt < b.addedAt
        case .name:
            result = a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        case .size:
            result = (a.totalBytes ?? 0) < (b.totalBytes ?? 0)
        case .status:
            result = statusOrder(a.status) < statusOrder(b.status)
        case .downloadSpeed:
            result = a.downloadSpeed < b.downloadSpeed
        case .uploadSpeed:
            result = a.uploadSpeed < b.uploadSpeed
        }
        return ascending ? result : !result
    }

    static func statusOrder(_ s: DownloadStatus) -> Int {
        switch s {
        case .downloading: return 0
        case .verifying: return 0
        case .requestingMetadata: return 1
        case .seeding: return 2
        case .queued: return 3
        case .paused: return 4
        case .failed: return 5
        case .completed: return 6
        }
    }

    static func count(tasks: [DownloadTask], filter: SidebarFilter) -> Int {
        tasks.filter { matches($0, filter: filter) }.count
    }
}
