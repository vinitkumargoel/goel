import Foundation
import GoelCore

/// What the menu bar needs to enable or disable its commands. The menus observe this instead of
/// the whole view model, so they rebuild when a boolean flips — not on every 10 Hz snapshot.
@MainActor
final class CommandState: ObservableObject {

    struct Snapshot: Equatable {
        /// Something Pause All would act on (running or waiting in line).
        var hasPausable = false
        /// Something Start All would act on.
        var hasResumable = false
        var isEmpty = true
        var hasSelection = false
        var selectionCanPause = false
        var selectionCanResume = false
        /// A selected row whose file is (still) on disk: Show in Finder / Move to Trash.
        var selectionHasData = false
        var hasCompletedVisible = false
        /// Any finished row at all, filtered out or not: Clear Completed acts on the whole list.
        var hasCompleted = false
        /// The download list is on screen (not the SFTP browser), so list commands apply.
        var listVisible = true
        var autoShutdown: AutoShutdownAction = .none

        static func make(tasks: [DownloadTask], visible: [DownloadTask],
                         selection: Set<DownloadTask.ID>, listVisible: Bool,
                         autoShutdown: AutoShutdownAction) -> Snapshot {
            var s = Snapshot()
            s.hasPausable = tasks.contains { $0.status.isActive || $0.status == .queued }
            s.hasResumable = tasks.contains { $0.status == .paused }
            s.isEmpty = visible.isEmpty
            s.listVisible = listVisible
            s.autoShutdown = autoShutdown
            s.hasCompletedVisible = visible.contains { $0.status == .completed }
            s.hasCompleted = tasks.contains { $0.status == .completed }
            let selected = listVisible ? visible.filter { selection.contains($0.id) } : []
            s.hasSelection = !selected.isEmpty
            s.selectionCanPause = selected.contains { $0.status.isActive }
            s.selectionCanResume = selected.contains { $0.status == .paused || $0.status == .queued }
            s.selectionHasData = selected.contains { $0.status.hasData }
            return s
        }
    }

    @Published private(set) var snapshot = Snapshot()

    /// Publishes only on a real change; that is the whole point of this object.
    @discardableResult
    func apply(_ next: Snapshot) -> Bool {
        guard next != snapshot else { return false }
        snapshot = next
        return true
    }
}
