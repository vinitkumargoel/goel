import Foundation
import GoelCore

@MainActor
extension AppViewModel {

    func isSelected(_ id: DownloadTask.ID) -> Bool { selection.contains(id) }

    func selectOnly(_ id: DownloadTask.ID) {
        selection = [id]
        primarySelection = id
    }

    func toggleSelection(_ id: DownloadTask.ID) {
        if selection.contains(id) {
            selection.remove(id)
            if primarySelection == id { primarySelection = selection.first }
        } else {
            selection.insert(id)
            primarySelection = id
        }
    }

    func selectAll() {
        selection = Set(visibleTasks.map(\.id))
        primarySelection = visibleTasks.first?.id
    }

    func selectCompleted() {
        let completed = visibleTasks.filter { $0.status == .completed }
        selection = Set(completed.map(\.id))
        primarySelection = completed.first?.id
    }

    func selectNone() {
        selection = []
        primarySelection = nil
    }

    func visibleNeighbor(after id: DownloadTask.ID) -> DownloadTask.ID? {
        guard let idx = visibleTasks.firstIndex(where: { $0.id == id }) else {
            return visibleTasks.first(where: { $0.id != id })?.id
        }
        if idx + 1 < visibleTasks.count { return visibleTasks[idx + 1].id }
        if idx - 1 >= 0 { return visibleTasks[idx - 1].id }
        return nil
    }
}
