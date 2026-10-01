import AppKit
import Foundation
import GoelCore

/// The "Review N links" step's side of the view model: sizes on demand, then one add for the
/// ticked rows that lands with them selected.
extension AppViewModel {

    struct ReviewedAddOptions {
        var saveDirectory: String?
        var priority: FilePriority = .normal
        var startAt: Date?
        var whenDone: WhenDone?
    }

    func reviewItems(for text: String) -> [LinkReviewItem] {
        LinkReview.items(from: text) { [tasks] source in
            tasks.first { $0.source.dedupKey == source.dedupKey }.map { L10n.t($0.status.displayName) }
        }
    }

    /// Size only: a HEAD (or a peer lookup for a magnet) through the same path the single-link preview uses.
    func reviewSize(for item: LinkReviewItem) async -> Int64? {
        guard case .url = item.source else { return nil }
        return await manager.resolveMetadata(for: item.source, saveDirectory: nil).totalBytes
    }

    /// Metalinks keep their own importer; everything else is added in order, with any inline
    /// login moved to the Keychain first, then selected so the list scrolls to it.
    func addReviewed(_ items: [LinkReviewItem], options: ReviewedAddOptions) {
        let metalinks = items.filter { Self.isMetalink($0.source) }
        if !metalinks.isEmpty {
            add(rawLines: metalinks.map(\.line).joined(separator: "\n"),
                saveDirectory: options.saveDirectory, priority: options.priority)
        }
        let links = items.filter { !Self.isMetalink($0.source) && existingDuplicate(of: $0.source) == nil }
        let skipped = items.count - metalinks.count - links.count
        guard !links.isEmpty else {
            if metalinks.isEmpty { toastWarning(L10n.t("Already in your list")) }
            return
        }
        if let folder = options.saveDirectory { RecentFolders.remember(folder) }
        let loginLines = InlineCredentials.linesWithLogins(in: links.map(\.line).joined(separator: "\n"))
        let manager = self.manager
        Task { [weak self] in
            for line in loginLines { await manager.adoptInlineCredentials(line, replaceExisting: true) }
            var added: [DownloadTask.ID] = []
            for item in links {
                let task = await manager.add(source: item.source, saveDirectory: options.saveDirectory,
                                             priority: options.priority, scheduledAt: options.startAt,
                                             whenDone: options.whenDone)
                added.append(task.id)
            }
            self?.announceReviewedAdd(added, skipped: skipped)
        }
        filter = .all
    }

    private func announceReviewedAdd(_ ids: [DownloadTask.ID], skipped: Int) {
        let message = skipped > 0
            ? L10n.t("Added %1$@ · skipped %2$@ already in your list", String(ids.count), String(skipped))
            : (ids.count == 1 ? L10n.t("Added to queue") : L10n.t("Added %d downloads to queue", ids.count))
        toastSuccess(message, action: Toast.Action(title: L10n.t("Show")) { [weak self] in
            self?.selectAdded(ids)
        })
        selectAdded(ids)
    }

    /// The rows arrive with the next snapshot; wait briefly for them rather than selecting nothing.
    func selectAdded(_ ids: [DownloadTask.ID]) {
        guard let first = ids.first else { return }
        Task { [weak self] in
            for _ in 0..<20 {
                guard let self else { return }
                if self.tasks.contains(where: { $0.id == first }) {
                    self.reveal(first)
                    let listed = Set(self.tasks.map(\.id))
                    self.selection = Set(ids.filter(listed.contains))
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// A playlist with a preset: each item goes through yt-dlp for its stream, one at a time,
    /// so a long list never starts dozens of yt-dlp processes. Without a preset the pages are
    /// queued as they are.
    func addPlaylist(_ items: [PlaylistItem], preset: MediaPreset?,
                     saveDirectory: String?, priority: FilePriority) {
        guard let preset else {
            add(rawLines: items.map(\.url).joined(separator: "\n"), saveDirectory: saveDirectory, priority: priority)
            return
        }
        let selector = preset.formatSelector(maxHeight: settings.hlsMaxHeight)
        let manager = self.manager
        toastNow(L10n.t("Resolving %d videos with yt-dlp…", items.count), kind: .info)
        filter = .all
        Task { [weak self] in
            var added: [DownloadTask.ID] = []
            var failed = 0
            for item in items {
                guard let page = URL(string: item.url),
                      case .resolved(let resolved) = await YtDlpResolver.resolveMedia(page, formatSelector: selector),
                      let preview = YtDlpResolver.preview(for: resolved) else { failed += 1; continue }
                let task = await manager.add(source: preview.source, saveDirectory: saveDirectory,
                                             priority: priority, suggestedName: preview.suggestedName)
                if let audio = preset.chainedAudio { self?.mediaJobs.chainedAudio[task.id] = audio }
                added.append(task.id)
            }
            self?.announcePlaylistAdd(added, failed: failed)
        }
    }

    private func announcePlaylistAdd(_ ids: [DownloadTask.ID], failed: Int) {
        guard !ids.isEmpty else {
            toastError(L10n.t("yt-dlp couldn’t resolve any of those videos"))
            return
        }
        let message = failed > 0
            ? L10n.t("Added %1$@ · %2$@ couldn’t be resolved", String(ids.count), String(failed))
            : L10n.t("Added %d downloads to queue", ids.count)
        toastSuccess(message, action: Toast.Action(title: L10n.t("Show")) { [weak self] in
            self?.selectAdded(ids)
        })
    }

    /// The clipboard banner's Options…: the link's preview, with folder, name and When done.
    func openClipboardSuggestionInAddSheet() {
        guard let link = clipboardSuggestion else { return }
        clipboardSuggestion = nil
        addSheetPrefill = link
        isAddSheetPresented = true
    }

    /// Dock menu and palette: whatever links are on the clipboard go through the Add sheet,
    /// so several get the review step and one gets its preview.
    func addFromClipboard() {
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        MainWindowPresenter.activate()
        guard !parsedSources(in: text).isEmpty else {
            toastWarning(L10n.t("No links on the clipboard"))
            return
        }
        addSheetPrefill = text
        isAddSheetPresented = true
    }
}
