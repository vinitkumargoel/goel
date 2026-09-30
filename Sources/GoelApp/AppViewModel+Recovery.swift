import Foundation
import GoelCore

/// The failure card's recovery steps and the multi-selection panel's bulk Move / Tag, each a thin
/// wrapper over one `DownloadManager` call plus the toast that reports how it went.
extension AppViewModel {

    /// Returns nil on success, or the reason to show in the sheet so the user can fix the link.
    func updateLink(of task: DownloadTask, to raw: String) async -> String? {
        let result = await manager.replaceSource(task.id, with: raw)
        switch result {
        case .replaced(let keepsPartial):
            toastNow(keepsPartial
                     ? L10n.t("Link updated · resuming if the file is unchanged")
                     : L10n.t("Link updated"))
            return nil
        case .invalidLink:
            return L10n.t("That isn’t an http or https link.")
        case .sameLink:
            return L10n.t("That is the link the download already uses.")
        case .duplicate(let name):
            return L10n.t("“%@” already downloads from that link.", name)
        case .busy:
            return L10n.t("Pause the download before changing its link.")
        case .finished:
            return L10n.t("A finished download keeps the link it came from.")
        case .unsupportedKind:
            return L10n.t("Only web (HTTP) downloads can change their link.")
        case .notFound:
            return L10n.t("The download is no longer in the list.")
        }
    }

    /// Cookies are scoped to the download's own host and never persisted (see `CookieHeader`).
    func attachCookies(_ header: String, to task: DownloadTask, retry: Bool) {
        Task {
            await manager.setCookies(header, host: task.sourceHost, source: .manual, task: task.id)
            if retry, task.status.isFailed { await manager.retry(task.id) }
        }
        toastNow(retry ? L10n.t("Cookies attached · retrying") : L10n.t("Cookies attached"))
    }

    func changeFolder(of task: DownloadTask, to directory: String) {
        Task {
            let result = await manager.relocate(task.id, to: directory)
            toastNow(Self.relocationMessage(result, name: task.name),
                     isError: result != .moved)
        }
    }

    func retryLater(_ task: DownloadTask, after delay: TimeInterval) {
        let when = Date().addingTimeInterval(delay)
        Task {
            guard await manager.retry(task.id, at: when) else { return }
            toastNow(L10n.t("Retrying “%1$@” at %2$@", task.name,
                            DisplayFormat.relativeDateTime(when, locale: DisplayFormat.appLocale)))
        }
    }

    // MARK: - Multi-selection

    /// Moves every selected download that can move; the rest are counted, not silently skipped.
    func moveSelected(to directory: String) {
        let targets = selectedTasks
        guard !targets.isEmpty else { return }
        Task {
            var moved = 0
            var skipped = 0
            for task in targets {
                if await manager.relocate(task.id, to: directory) == .moved { moved += 1 } else { skipped += 1 }
            }
            if skipped == 0 {
                toastNow(moved == 1 ? L10n.t("Moved %d download", moved) : L10n.t("Moved %d downloads", moved))
            } else {
                toastNow(L10n.t("Moved %1$@, %2$@ couldn’t move (running, finished, or a file is in the way)",
                                String(moved), String(skipped)),
                         isError: moved == 0)
            }
        }
    }

    /// Adds the typed tags to every selected download, keeping the tags each already has.
    func promptForTagsOnSelection() {
        let targets = selectedTasks
        guard !targets.isEmpty else { return }
        guard let value = Self.promptText(
            title: L10n.t("Add tags to %d downloads", targets.count),
            message: L10n.t("Comma-separated. Each download keeps the tags it already has."),
            confirm: "Add", initial: "",
            placeholder: "e.g. work, urgent, linux") else { return }
        let added = PromptParsing.tags(from: value)
        guard !added.isEmpty else { return }
        Task {
            for task in targets {
                await manager.setTags(task.allTags + added, task: task.id)
            }
        }
        toastNow(L10n.t("Tagged %d downloads", targets.count))
    }

    static func relocationMessage(_ result: DownloadManager.Relocation, name: String) -> String {
        switch result {
        case .moved: return L10n.t("Moved “%@” · retrying", name)
        case .sameFolder: return L10n.t("“%@” is already in that folder", name)
        case .busy: return L10n.t("Pause “%@” before moving it", name)
        case .finished: return L10n.t("“%@” is finished — move the file in Finder instead", name)
        case .unsupportedKind:
            return L10n.t("“%@” has already written data and can’t change folder", name)
        case .conflict: return L10n.t("A file named “%@” is already in that folder", name)
        case .changedDuringMove: return L10n.t("“%@” changed while moving; nothing was moved", name)
        case .notFound: return L10n.t("The download is no longer in the list.")
        case .failed(let reason): return L10n.t("Couldn’t move “%1$@”: %2$@", name, reason)
        }
    }
}
