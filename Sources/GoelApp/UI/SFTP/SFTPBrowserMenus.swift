import SwiftUI
import GoelCore

/// The browser's context menus: one item, several items, and the empty area of the folder.
extension SFTPBrowserView {

    @ViewBuilder
    func rowMenu(_ entry: SFTPEntry) -> some View {
        let targets = actionTargets(for: entry)
        if targets.count > 1 {
            Button(L10n.t("Download %d Items", targets.count)) { downloadTargets(targets) }
            Button(L10n.t("Download %d Items to…", targets.count)) { chooseDownloadFolder(forAll: targets) }
            Divider()
            clipboardMenuItems(targets)
            Divider()
            Button(L10n.t("Delete %d Items", targets.count), role: .destructive) { deleteTargets(targets) }
        } else {
            if entry.isDirectory {
                Button(L10n.t("Open")) { Task { await model.open(entry) } }
                Divider()
                Button(L10n.t("Download Folder")) { downloadTargets([entry]) }
                Button(L10n.t("Download Folder to…")) { chooseDownloadFolder(for: entry) }
            } else {
                Button(L10n.t("Download")) { downloadTargets([entry]) }
                Button(L10n.t("Download to…")) { chooseDownloadFolder(for: entry) }
                Button(L10n.t("Add to Download Queue")) {
                    vm.enqueueSFTPDownload(connection: model.connection, remotePath: remotePath(entry))
                }
                Button(L10n.t("Quick Look")) { quickLook(entry) }
            }
            Divider()
            Button(L10n.t("Get Info")) { showInfo(entry) }
            clipboardMenuItems([entry])
            Divider()
            Button(L10n.t("Rename…")) { requestRename(entry) }
            moveMenu(entry)
            Button(L10n.t("Copy Path")) { copyToPasteboard(remotePath(entry)) }
            Button(L10n.t("Copy sftp:// Link")) { copyToPasteboard(sftpURL(entry)) }
            Divider()
            Button(L10n.t("Delete"), role: .destructive) { deleteTargets([entry]) }
        }
    }

    @ViewBuilder
    func clipboardMenuItems(_ targets: [SFTPEntry]) -> some View {
        Button(targets.count == 1 ? L10n.t("Copy") : L10n.t("Copy %d Items", targets.count)) {
            vm.copySFTPItems(targets, from: model.connection, directory: model.path, operation: .copy)
        }
        Button(targets.count == 1 ? L10n.t("Cut") : L10n.t("Cut %d Items", targets.count)) {
            vm.copySFTPItems(targets, from: model.connection, directory: model.path, operation: .cut)
        }
        Button(targets.count == 1 ? L10n.t("Duplicate") : L10n.t("Duplicate %d Items", targets.count)) {
            vm.duplicateSFTPItems(targets, on: model.connection, directory: model.path)
        }
        pasteItem
    }

    @ViewBuilder
    private var pasteItem: some View {
        if let clip = vm.sftpClipboard, !clip.isEmpty {
            Button(clip.pasteLabel) {
                vm.pasteSFTPClipboard(into: model.connection, directory: model.path)
            }
            .disabled(!vm.canPasteSFTP(into: model.connection, directory: model.path))
        }
    }

    @ViewBuilder
    func moveMenu(_ entry: SFTPEntry) -> some View {
        Menu(L10n.t("Move to")) {
            if !model.isAtRoot {
                Button(L10n.t("⬆︎ Parent folder")) { move(entry, toParent: true, folder: nil) }
                Divider()
            }
            // `folder.name` is server-supplied: an entry named "../.." must not escape the tree.
            let folders = model.entries.filter {
                $0.isDirectory && $0.id != entry.id && SFTPBrowserPaths.isSafeChildName($0.name)
            }
            if folders.isEmpty {
                Text(L10n.t("No subfolders"))
            } else {
                ForEach(folders) { folder in
                    Button(folder.name) { move(entry, toParent: false, folder: folder) }
                }
            }
        }
    }

    @ViewBuilder
    var emptyAreaMenu: some View {
        Button(L10n.t("New Folder")) { requestNewFolder() }
        Button(L10n.t("Upload…")) { chooseUploadItems() }
        pasteItem
        Divider()
        Button(showHidden ? L10n.t("Hide Hidden Files") : L10n.t("Show Hidden Files")) { showHidden.toggle() }
        if !selection.isEmpty { Button(L10n.t("Deselect All")) { selection.removeAll() } }
    }

    private func move(_ entry: SFTPEntry, toParent: Bool, folder: SFTPEntry?) {
        Task {
            if toParent {
                if await model.move(entry, toDirectory: SFTPBrowserModel.parent(of: model.path)) {
                    vm.toastSuccess(L10n.t("Moved “%@”", entry.name))
                } else {
                    showFailure(L10n.t("Couldn’t move “%@” to the parent folder", entry.name))
                }
            } else if let folder {
                if await model.move(entry, toDirectory: SFTPBrowserModel.join(model.path, folder.name)) {
                    vm.toastSuccess(L10n.t("Moved to “%@”", folder.name))
                } else {
                    showFailure(L10n.t("Couldn’t move “%1$@” to “%2$@”", entry.name, folder.name))
                }
            }
        }
    }
}
