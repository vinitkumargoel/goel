import Foundation
import GoelCore

/// App-layer adapter over ``TaskListQuery`` — maps sidebar/sort chrome enums
/// onto the pure core query (including the `.type` file-kind filter).
enum ListPresentation {

    static func visible(
        tasks: [DownloadTask],
        filter: SidebarFilter,
        search: String,
        sortKey: SortKey,
        ascending: Bool
    ) -> [DownloadTask] {
        switch filter {
        case .type(let t):
            return TaskListQuery.visible(
                tasks: tasks,
                filter: .all,
                search: search,
                sortKey: mapSort(sortKey),
                ascending: ascending,
                extraMatch: { $0.fileType == t }
            )
        default:
            return TaskListQuery.visible(
                tasks: tasks,
                filter: mapFilter(filter),
                search: search,
                sortKey: mapSort(sortKey),
                ascending: ascending
            )
        }
    }

    static func matches(_ task: DownloadTask, filter: SidebarFilter) -> Bool {
        switch filter {
        case .type(let t): return task.fileType == t
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
        case .type(let t): return tasks.filter { $0.fileType == t }.count
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
        case .type: return .all
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
