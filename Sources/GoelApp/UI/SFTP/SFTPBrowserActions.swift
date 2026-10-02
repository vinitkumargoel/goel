import SwiftUI
import AppKit
import GoelCore

/// Everything the browser does to the server or the Mac: folders, renames, deletes, downloads,
/// uploads, previews, info and permissions. Failures go to the banner (`showFailure`).
extension SFTPBrowserView {

    // MARK: - Targets

    func actionTargets(for entry: SFTPEntry) -> [SFTPEntry] {
        if selection.contains(entry.id) && selection.count > 1 { return selectedEntries }
        return [entry]
    }

    func clipboardTargets() -> [SFTPEntry] {
        let selected = selectedEntries
        if !selected.isEmpty { return selected }
        return visibleEntries.filter { $0.id == cursor }
    }

    func remotePath(_ entry: SFTPEntry) -> String { SFTPBrowserModel.join(model.path, entry.name) }

    func sftpURL(_ entry: SFTPEntry) -> String {
        SFTPBrowserListing.sftpLink(model.connection, remotePath: remotePath(entry))
    }

    // MARK: - Names

    func requestNewFolder() {
        // Finder's default, so Return alone makes a folder; Create stays off for a blank name.
        nameRequest = SFTPNameRequest(kind: .newFolder, initialName: RemoteNameInput.defaultFolderName)
    }

    func requestRename(_ entry: SFTPEntry) {
        nameRequest = SFTPNameRequest(kind: .rename(entry), initialName: entry.name)
    }

    func commitName(_ request: SFTPNameRequest, _ text: String) {
        switch request.kind {
        case .newFolder: createFolder(named: text)
        case .rename(let entry): rename(entry, to: text)
        }
    }

    private func createFolder(named text: String) {
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            if await model.makeDirectory(named: name) {
                vm.toastSuccess(L10n.t("Folder created"))
            } else if !name.isEmpty {
                showFailure(L10n.t("Couldn’t create the folder “%@”", name))
            }
        }
    }

    private func rename(_ entry: SFTPEntry, to newName: String) {
        Task {
            if await model.rename(entry, to: newName) {
                vm.toastSuccess(L10n.t("Renamed"))
            } else if newName.trimmingCharacters(in: .whitespacesAndNewlines) != entry.name {
                // Confirming the prefilled name unchanged is a no-op, not a failure.
                showFailure(L10n.t("Couldn’t rename “%@”", entry.name))
            }
        }
    }

    // MARK: - Delete

    /// Every delete asks first, in the window's confirm card: one item names itself, several are counted.
    func deleteTargets(_ entries: [SFTPEntry]) {
        guard let first = entries.first else { return }
        if entries.count == 1 {
            vm.requestConfirm(
                title: L10n.t("Delete “%@”?", first.name),
                message: first.isDirectory
                    ? L10n.t("The folder and everything inside it will be permanently removed from the server.")
                    : L10n.t("This permanently removes the file from the server."),
                confirmTitle: L10n.t("Delete"), destructive: true
            ) { deleteOne(first) }
            return
        }
        vm.requestConfirm(
            title: L10n.t("Delete %d items?", entries.count),
            message: L10n.t("This permanently removes them from the server. Folders are removed with everything "
                + "inside them."),
            confirmTitle: L10n.t("Delete"), destructive: true
        ) {
            Task {
                // Count them: an unreported refusal mid-batch reads as a clean sweep.
                let result = await model.deleteMany(entries)
                selection.removeAll()
                if let failure = result.failure {
                    // A partial result must stay readable: the banner, not a toast that times out.
                    model.error = result.deleted > 0
                        ? L10n.t("Deleted %1$d of %2$d items — %3$@", result.deleted, entries.count, failure)
                        : failure
                } else {
                    vm.toastSuccess(L10n.t("Deleted %d items", result.deleted))
                }
            }
        }
    }

    private func deleteOne(_ entry: SFTPEntry) {
        Task {
            if await model.delete(entry) {
                vm.toastSuccess(L10n.t("Deleted “%@”", entry.name))
            } else {
                showFailure(L10n.t("Couldn’t delete “%@”", entry.name))
            }
        }
    }

    // MARK: - Clipboard

    func copySelection(_ operation: SFTPClipboard.Operation) {
        let targets = clipboardTargets()
        guard !targets.isEmpty else { return }
        vm.copySFTPItems(targets, from: model.connection, directory: model.path, operation: operation)
    }

    func duplicateSelection() {
        let targets = clipboardTargets()
        guard !targets.isEmpty else { return }
        vm.duplicateSFTPItems(targets, on: model.connection, directory: model.path)
    }

    func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        vm.toastSuccess(L10n.t("Copied"))
    }

    // MARK: - Open / preview

    func primaryAction(_ entry: SFTPEntry) {
        // Finder's double-click: folders open, files preview. Downloading is an explicit choice.
        if entry.isDirectory { Task { await model.open(entry) } }
        else { quickLook(entry) }
    }

    func openSoleSearchResult() {
        guard visibleEntries.count == 1, let only = visibleEntries.first, only.isDirectory else { return }
        Task { await model.open(only) }
    }

    private var previewByteCap: Int64 { 512 * 1024 * 1024 }

    func quickLook(_ entry: SFTPEntry) {
        guard !entry.isDirectory, let client else { return }
        guard entry.size < previewByteCap else { model.error = L10n.t("Too large to preview"); return }
        let safe = PathSafety.sanitizedName(entry.name)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(QuickLookPresenter.tempPrefix + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(safe)
        let remote = SFTPBrowserModel.join(model.path, entry.name)
        // `entry.size` is the server's claim: a reported 0 would stream unbounded data to temp.
        let cap = ByteCap(limit: previewByteCap)
        vm.toastNow(L10n.t("Preparing preview…"))
        Task {
            do {
                try await client.downloadToFile(remote: remote, localURL: tmp,
                                                shouldContinue: { cap.underLimit }) { sofar, total in
                    cap.observe(sofar: sofar, total: total)
                }
                guard cap.underLimit else {
                    try? FileManager.default.removeItem(at: dir)
                    await MainActor.run { model.error = L10n.t("Too large to preview") }
                    return
                }
                await MainActor.run { QuickLookPresenter.shared.present(tmp, ownedDirectory: dir) }
            } catch {
                try? FileManager.default.removeItem(at: dir)
                let message = cap.underLimit
                    ? L10n.t("Couldn’t preview “%@”", entry.name) : L10n.t("Too large to preview")
                await MainActor.run { model.error = message }
            }
        }
    }

    // MARK: - Info

    func showInfo(_ entry: SFTPEntry) {
        closeInfo()
        info.entry = entry
        Task {
            let fetched = await model.info(for: entry)
            // The sheet may have moved on to another item while this was in flight.
            if info.entry?.id == entry.id { info.info = fetched }
        }
        guard entry.isDirectory else { return }
        let cancel = CancelFlag()
        infoSizeCancel = cancel
        info.isSizing = true
        infoSizeTask = Task {
            let result = await model.recursiveSize(of: entry, shouldContinue: { !cancel.isCancelled })
            // A cancelled walk must not write its partial answer into a closed panel.
            guard !cancel.isCancelled else { return }
            switch result {
            case .success(let size): info.folderSize = size
            case .failure(let e): info.sizeError = e.message
            case nil: break
            }
            info.isSizing = false
            infoSizeTask = nil
        }
    }

    func closeInfo() {
        infoSizeCancel?.cancel()
        infoSizeTask?.cancel()
        infoSizeTask = nil
        infoSizeCancel = nil
        info = SFTPInfoState()
    }

    /// With the info sheet open, a single newly selected item takes its place.
    func followSelectionWithInfo(_ next: Set<SFTPEntry.ID>) {
        guard let shown = info.entry, next.count == 1, let id = next.first, id != shown.id,
              let entry = visibleEntries.first(where: { $0.id == id }) else { return }
        showInfo(entry)
    }

    func applyPermissions(_ entry: SFTPEntry, _ mode: UInt32) {
        Task {
            if await model.setPermissions(entry, mode: mode) {
                vm.toastSuccess(L10n.t("Permissions updated"))
                info.info = await model.info(for: entry)
            } else {
                showFailure(L10n.t("Couldn’t change permissions for “%@”", entry.name))
            }
        }
    }

    // MARK: - Download

    /// The folder Settings' "Default folder" rule picks for this name, as an HTTP file would get.
    private func ruleDir(for entry: SFTPEntry) -> URL {
        let kind: DownloadKind = entry.isDirectory ? .sftp : .http
        let base = vm.settings.defaultSaveDirectory
        let path: String
        switch vm.settings.defaultFolderRule {
        case "byType", "automatic":
            let category = entry.isDirectory ? "Other" : DiskSpaceCheck.categoryFolder(kind: kind, name: entry.name)
            path = (base as NSString).appendingPathComponent(category)
        case "bySource":
            path = (base as NSString).appendingPathComponent("HTTP Downloads")
        default:
            path = base
        }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }

    func downloadTargets(_ entries: [SFTPEntry], to chosen: URL? = nil) {
        let items = entries.filter { SFTPBrowserPaths.isSafeChildName($0.name) }
        guard !items.isEmpty else { vm.toastWarning(L10n.t("Select items to download")); return }
        var folders: Set<String> = []
        for item in items {
            let dir = chosen ?? ruleDir(for: item)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            folders.insert(dir.lastPathComponent)
            vm.startDownload(item, from: model.connection, remoteDir: model.path, toLocalDir: dir)
        }
        let place = folders.count == 1 ? (folders.first ?? "") : L10n.t("your download folders")
        vm.toastNow(items.count == 1 ? L10n.t("Downloading “%1$@” to %2$@", items[0].name, place)
                                     : L10n.t("Downloading %1$d items to %2$@", items.count, place))
    }

    func chooseDownloadFolder(forAll entries: [SFTPEntry]) {
        if let dir = FilePicker.chooseDirectory(
            prompt: L10n.t("Download Here"),
            message: L10n.t("Choose where to save %d items", entries.count)) {
            downloadTargets(entries, to: dir)
        }
    }

    func chooseDownloadFolder(for entry: SFTPEntry) {
        if let dir = FilePicker.chooseDirectory(
            prompt: L10n.t("Download Here"),
            message: L10n.t("Choose where to save “%@”", entry.name)) {
            vm.startDownload(entry, from: model.connection, remoteDir: model.path, toLocalDir: dir)
        }
    }

    // MARK: - Upload

    func handleUploadDrop(_ providers: [NSItemProvider]) -> Bool {
        let connection = model.connection
        let remoteDir = model.path
        return collectDroppedURLs(providers, fileURLsOnly: true) { urls in
            if !urls.isEmpty { vm.startUpload(items: urls, toRemoteDir: remoteDir, on: connection) }
        }
    }

    func handleUploadDrop(_ providers: [NSItemProvider], into folder: SFTPEntry) -> Bool {
        // `folder.name` is untrusted server listing data: refuse separators and traversal.
        guard SFTPBrowserPaths.isSafeChildName(folder.name) else {
            model.error = L10n.t("Can’t upload into “%@”", folder.name)
            return false
        }
        let connection = model.connection
        let remoteDir = SFTPBrowserModel.join(model.path, folder.name)
        return collectDroppedURLs(providers, fileURLsOnly: true) { urls in
            if !urls.isEmpty {
                vm.startUpload(items: urls, toRemoteDir: remoteDir, on: connection)
                vm.toastNow(L10n.t("Uploading to “%@”", folder.name))
            }
        }
    }

    func chooseUploadItems() {
        let urls = FilePicker.openItems(
            canChooseFiles: true, canChooseDirectories: true,
            prompt: L10n.t("Upload"),
            message: L10n.t("Choose files or folders to upload to %@", model.displayPath))
        if !urls.isEmpty {
            vm.startUpload(items: urls, toRemoteDir: model.path, on: model.connection)
        }
    }

    // MARK: - Failures

    /// A failed action goes to the banner, which stays until dismissed and can be copied.
    /// The model's own message, when it set one, is more specific than the fallback.
    func showFailure(_ fallback: String) {
        model.error = model.error ?? fallback
    }
}
