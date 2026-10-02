#if DEBUG
import SwiftUI
import GoelCore

/// The SFTP area's snapshots. Owned by the SFTP area agent: add entries here only, named
/// `sftp.<screen>`, e.g. `StudioSnapshotEntry("sftp.example", width: 900) { context in … }`.
/// Render them with `GoelDownloader --studio-snapshots <outdir> --only sftp.`
@MainActor
enum SFTPSnapshots {
    static var entries: [StudioSnapshotEntry] {
        browser + browserStates + info + editor + transfers
    }

    private typealias F = SFTPSampleFixture

    /// The sample model with the sample servers and (optionally) transfers in it.
    private static func prepare(_ context: StudioSnapshotContext, transfers: [SFTPTransfer]? = nil) -> AppViewModel {
        let vm = context.model
        F.install(into: vm, transfers: transfers)
        return vm
    }

    private static func browser(_ preview: SFTPBrowserPreview, _ vm: AppViewModel) -> some View {
        SFTPBrowserView(connection: F.nas, preview: preview)
            .studioSampleEnvironment(vm)
    }

    private static var browser: [StudioSnapshotEntry] {
        [
            StudioSnapshotEntry("sftp.browser.grid", width: 1180, height: 920) { context in
                let selected = F.entry("project-backup-2026-06.tar.zst")
                let list = F.transfers()
                return browser(SFTPBrowserPreview(
                    path: F.path, entries: F.entries, isGrid: true, selection: [selected.id],
                    volumeSpace: F.volume,
                    info: SFTPInfoState(entry: selected, info: F.info(for: selected)),
                    transferHistory: F.history(for: list)), prepare(context, transfers: list))
            },
            StudioSnapshotEntry("sftp.browser.list", width: 1180, height: 920) { context in
                let list = F.transfers()
                return browser(SFTPBrowserPreview(
                    path: F.path, entries: F.entries, isGrid: false,
                    selection: [F.entry("db-dump-2026-10-01.sql.gz").id, F.entry("notes.md").id],
                    volumeSpace: F.volume, transferHistory: F.history(for: list)),
                               prepare(context, transfers: list))
            },
            StudioSnapshotEntry("sftp.browser.list.quiet", width: 1000, height: 620) { context in
                browser(SFTPBrowserPreview(
                    path: F.path, entries: F.entries, isGrid: false, searchText: "backup",
                    volumeSpace: F.volume), prepare(context, transfers: []))
            },
            StudioSnapshotEntry("sftp.browser.narrow", width: 760, height: 620) { context in
                browser(SFTPBrowserPreview(
                    path: F.path, entries: F.entries, isGrid: true,
                    volumeSpace: F.volume), prepare(context, transfers: []))
            },
        ]
    }

    private static var browserStates: [StudioSnapshotEntry] {
        [
            StudioSnapshotEntry("sftp.browser.empty", width: 1000, height: 560) { context in
                browser(SFTPBrowserPreview(path: "/home/vinit/backups/2024", entries: [],
                                           volumeSpace: F.volume), prepare(context, transfers: []))
            },
            StudioSnapshotEntry("sftp.browser.nomatch", width: 1000, height: 560) { context in
                browser(SFTPBrowserPreview(path: F.path, entries: F.entries, searchText: "invoice",
                                           volumeSpace: F.volume), prepare(context, transfers: []))
            },
            StudioSnapshotEntry("sftp.browser.error", width: 1000, height: 560) { context in
                browser(SFTPBrowserPreview(
                    path: F.path, entries: F.entries, isGrid: false,
                    error: "Couldn’t delete “vm-images”: Permission denied. The server refused to remove "
                        + "/home/vinit/backups/vm-images/debian-12.qcow2 (SSH_FX_PERMISSION_DENIED). "
                        + "Check that your account owns the folder, then try again.",
                    deleteProgress: "Deleting “photos-raw” — 240 of 1204 items…",
                    volumeSpace: F.volume), prepare(context, transfers: []))
            },
            StudioSnapshotEntry("sftp.browser.drop", width: 1000, height: 560) { context in
                browser(SFTPBrowserPreview(path: F.path, entries: F.entries, isGrid: true,
                                           volumeSpace: F.volume, dropTargeted: true),
                        prepare(context, transfers: []))
            },
        ]
    }

    private static var info: [StudioSnapshotEntry] {
        [
            StudioSnapshotEntry("sftp.info.file", width: 360, height: 640) { context in
                let entry = F.entry("project-backup-2026-06.tar.zst")
                return infoPanel(entry, info: F.info(for: entry))
                    .studioSampleEnvironment(prepare(context))
            },
            StudioSnapshotEntry("sftp.info.folder", width: 360, height: 640) { context in
                let entry = F.entry("photos-raw")
                return infoPanel(entry, info: F.info(for: entry), isSizing: true)
                    .studioSampleEnvironment(prepare(context))
            },
            StudioSnapshotEntry("sftp.info.symlink", width: 360, height: 640) { context in
                let entry = F.entry("latest.tar.zst")
                return infoPanel(entry, info: F.info(for: entry))
                    .studioSampleEnvironment(prepare(context))
            },
        ]
    }

    private static func infoPanel(_ entry: SFTPEntry, info: SFTPEntryInfo?, isSizing: Bool = false) -> some View {
        SFTPInfoPanel(entry: entry, info: info, folderSize: nil, isSizing: isSizing,
                      onApplyPermissions: { _ in }, onClose: {}, onDownload: {}, onPreview: {})
            .padding(Studio.Space.xl)
            .background(Studio.Palette.canvas)
    }

    private static var editor: [StudioSnapshotEntry] {
        [
            StudioSnapshotEntry("sftp.editor.empty", width: 520) { context in
                SFTPConnectionEditor(existing: nil).studioSampleEnvironment(prepare(context))
            },
            StudioSnapshotEntry("sftp.editor.filled", width: 520) { context in
                SFTPConnectionEditor(existing: nil, preview: filledDraft(result: nil))
                    .studioSampleEnvironment(prepare(context))
            },
            StudioSnapshotEntry("sftp.editor.tested", width: 520) { context in
                SFTPConnectionEditor(existing: nil, preview: filledDraft(
                    result: .success(fingerprint: "SHA256:q8Xb3Lw0fZt1u7mKc9vR2yNe4hJpA5sD6gT0oWiQ1Ek")))
                    .studioSampleEnvironment(prepare(context))
            },
            StudioSnapshotEntry("sftp.editor.failed", width: 520) { context in
                SFTPConnectionEditor(existing: F.seedbox, preview: filledDraft(
                    result: .failure(message: "The server rejected the key and the password for vinit.",
                                     detail: "libssh2 error -18: Authentication failed (publickey,password)",
                                     retry: .test),
                    confirmingReset: true))
                    .studioSampleEnvironment(prepare(context))
            },
        ]
    }

    private static func filledDraft(result: SFTPConnectionTestResult?,
                                    confirmingReset: Bool = false) -> SFTPConnectionEditorPreview {
        SFTPConnectionEditorPreview(
            address: "sftp://vinit@ams3.seedbox.example.net:22/home/vinit/done",
            name: "seedbox-ams", host: "ams3.seedbox.example.net", port: "22", username: "vinit",
            initialPath: "/home/vinit/done", useAgent: true,
            privateKeyPath: "/etc/hosts", keyPassphrase: "correct horse",
            addressFilled: true, testResult: result, confirmingHostKeyReset: confirmingReset)
    }

    private static var transfers: [StudioSnapshotEntry] {
        [
            StudioSnapshotEntry("sftp.transfers.panel", width: 1100) { context in
                let list = F.transfers().filter { $0.connectionID == F.nas.id }
                return SFTPTransferPanel(transfers: list, connection: F.nas, volumeSpace: F.volume,
                                         historyOverride: F.history(for: list))
                    .padding(.top, Studio.Space.xl)
                    .background(Studio.Palette.canvas)
                    .studioSampleEnvironment(prepare(context, transfers: list))
            },
            StudioSnapshotEntry("sftp.transfers.panel.narrow", width: 720) { context in
                let list = F.transfers().filter { $0.connectionID == F.nas.id }
                return SFTPTransferPanel(transfers: list, connection: F.nas, volumeSpace: F.volume,
                                         historyOverride: F.history(for: list))
                    .padding(.top, Studio.Space.xl)
                    .background(Studio.Palette.canvas)
                    .studioSampleEnvironment(prepare(context, transfers: list))
            },
            StudioSnapshotEntry("sftp.transfers.all", width: 600, height: 560) { context in
                SFTPAllTransfersView().studioSampleEnvironment(prepare(context))
            },
            StudioSnapshotEntry("sftp.transfers.all.empty", width: 600, height: 440) { context in
                SFTPAllTransfersView().studioSampleEnvironment(prepare(context, transfers: []))
            },
            StudioSnapshotEntry("sftp.transfers.rows", width: 380) { context in
                let vm = prepare(context)
                return VStack(spacing: 0) {
                    ForEach(F.transfers()) { transfer in
                        SFTPTransferRow(transfer: transfer, density: .compact, serverLabel: "nas.home",
                                        onCancel: {}, onRetry: {}, onPause: {}, onResume: {},
                                        onShowRemoteFolder: {})
                        StudioDivider()
                    }
                    ForEach(F.transfers().prefix(3)) { transfer in
                        SFTPTransferRow(transfer: transfer, density: .full, serverLabel: "nas.home",
                                        onCancel: {}, onRetry: {}, onPause: {}, onResume: {})
                        StudioDivider()
                    }
                }
                .background(Studio.Palette.cardRaised)
                .studioSampleEnvironment(vm)
            },
            StudioSnapshotEntry("sftp.conflict", width: 560) { context in
                SFTPUploadConflictSheet(request: F.conflictRequest(), onResolve: { _ in }, onCancel: {})
                    .studioSampleEnvironment(prepare(context))
            },
            StudioSnapshotEntry("sftp.namesheet", width: 400) { context in
                SFTPNameSheet(request: SFTPNameRequest(kind: .newFolder,
                                                       initialName: RemoteNameInput.defaultFolderName),
                              onCancel: {}, onCommit: { _ in })
                    .studioSampleEnvironment(prepare(context))
            },
        ]
    }
}
#endif
