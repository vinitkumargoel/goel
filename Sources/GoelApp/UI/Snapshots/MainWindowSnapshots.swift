#if DEBUG
import SwiftUI
import GoelCore

/// The MainWindow area's snapshots. Owned by the MainWindow area agent: add entries here only, named
/// `main.<screen>`, e.g. `StudioSnapshotEntry("main.example", width: 900) { context in … }`.
/// Render them with `GoelDownloader --studio-snapshots <outdir> --only main.`
@MainActor
enum MainWindowSnapshots {
    static var entries: [StudioSnapshotEntry] {
        [
            window("main.window"),
            window("main.window.rail-expanded", preview: MainWindowPreview(railExpanded: true)),
            window("main.flyout.filters", preview: MainWindowPreview(railExpanded: false, flyout: .filters)),
            window("main.flyout.servers", preview: MainWindowPreview(railExpanded: false, flyout: .servers)),
            window("main.flyout.tags", preview: MainWindowPreview(railExpanded: false, flyout: .tags)),
            window("main.omnibox.link", preview: MainWindowPreview(
                railExpanded: false,
                omniboxText: "https://releases.ubuntu.com/24.04.1/ubuntu-24.04.1-live-server-amd64.iso",
                omniboxFocused: true)),
            window("main.omnibox.clipboard") { model in
                model.clipboardSuggestion = "https://releases.ubuntu.com/24.04.1/ubuntu-24.04.1-live-server-amd64.iso"
            },
            window("main.nomatch", preview: MainWindowPreview(railExpanded: false, omniboxText: "host:archive.org mozart")) { model in
                model.filter = .type(.audio)
                model.search = "host:archive.org mozart"
            },
            window("main.banners") { model in
                model.persistenceWarning = "Couldn’t open the download database. Changes this session won’t be saved."
                model.serverStoreWarning = "The saved-servers file couldn’t be read."
            },
            window("main.empty", empty: true),
            window("main.empty.clipboard", preview: MainWindowPreview(
                railExpanded: true,
                clipboardLink: "https://cdimage.debian.org/debian-cd/current/arm64/iso-cd/debian-12.7.0-arm64-netinst.iso"),
                   empty: true),
            // Search hidden under Customize: the omnibox folds to a magnifier...
            window("main.search.hidden", preview: MainWindowPreview(
                railExpanded: false, toolbarSlots: [.pauseResume, .inspector])),
            // ...and unfolds again to carry a copied link, so paste-to-add still works.
            window("main.search.hidden.clipboard", preview: MainWindowPreview(
                railExpanded: false, toolbarSlots: [.pauseResume, .inspector])) { model in
                model.clipboardSuggestion = "https://releases.ubuntu.com/24.04.1/ubuntu-24.04.1-live-server-amd64.iso"
            },
            window("main.drop", preview: MainWindowPreview(railExpanded: false, isDropTargeted: true)),
            window("main.confirm") { model in
                model.requestConfirm(
                    title: "Remove the tag “linux” from every download?",
                    message: "The downloads stay; only the tag goes.",
                    confirmTitle: "Remove Tag", destructive: true) {}
            },
            // Too narrow for the floating sheet beside an expanded rail: the detail docks underneath.
            window("main.narrow", width: 900, height: 720, preview: MainWindowPreview(railExpanded: true)),
            StudioSnapshotEntry("main.toasts", width: 520) { context in
                prepare(context.model)
                return ToastGallery(queues: ToastGallery.makeQueues()).padding(24).background(Studio.Palette.canvas)
            },
            StudioSnapshotEntry("main.statusbar", width: 1280) { context in
                prepare(context.model)
                context.model.sftpTransfers = sampleTransfers()
                return StatusBarGallery(model: context.model)
                    .studioSampleEnvironment(context.model)
            },
            // Last: leaves the shared sample model as it found it for the areas that render after.
            StudioSnapshotEntry("main.header.customize", width: 520) { context in
                prepare(context.model)
                return HeaderCustomizePopover(raw: .constant(""))
                    .padding(24)
                    .background(Studio.Palette.canvas)
            },
        ]
    }

    private static func window(_ name: String, width: CGFloat = 1280, height: CGFloat = 860,
                               preview: MainWindowPreview = MainWindowPreview(railExpanded: false),
                               empty: Bool = false,
                               configure: @escaping @MainActor (AppViewModel) -> Void = { _ in }) -> StudioSnapshotEntry {
        StudioSnapshotEntry(name, width: width, height: height) { context in
            let model = context.model
            prepare(model)
            if empty { model.installSampleSnapshot([], selecting: nil) }
            configure(model)
            return RootView()
                .environment(\.mainWindowPreview, preview)
                .studioSampleEnvironment(model)
        }
    }

    /// Resets what the entries change on the shared model, then adds the servers the rail lists.
    private static func prepare(_ model: AppViewModel) {
        _ = StudioSampleData.makeViewModel()
        model.search = ""
        model.filter = .all
        model.clipboardSuggestion = nil
        model.confirmRequest = nil
        model.persistenceWarning = nil
        model.serverStoreWarning = nil
        model.detailPanelVisible = true
        model.detailDockForcedBottom = false
        model.sftpTransfers = []
        let nas = SFTPConnection(id: serverID(1), name: "nas.home", host: "nas.home", username: "vinit")
        let seedbox = SFTPConnection(id: serverID(2), name: "Seedbox", host: "seedbox.example.net", username: "goel")
        model.servers = [nas, seedbox]
        model.serverMeta = [
            nas.id: ServerMeta(reachability: .online, ip: "192.168.0.234", latencyMS: 4,
                               os: ServerOS(id: "ubuntu", pretty: "Ubuntu 24.04 LTS")),
            seedbox.id: ServerMeta(reachability: .offline, offlineDetail: "Connection refused"),
        ]
    }

    private static func serverID(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "5E7E7000-0000-0000-0000-%012d", n))!
    }

    fileprivate static func sampleTransfers() -> [SFTPTransfer] {
        var upload = SFTPTransfer(connectionID: serverID(1), name: "holiday-photos.zip", direction: .upload,
                                  isDirectory: false, localURL: nil, remotePath: "/srv/backup/holiday-photos.zip",
                                  total: 1_800_000_000)
        upload.bytes = 1_100_000_000
        upload.speed = 9_400_000
        upload.state = .running
        return [upload]
    }
}

/// Every toast kind, with an Undo and a "+N waiting" queue.
@MainActor
private struct ToastGallery: View {
    let queues: [ToastQueue]

    static func makeQueues() -> [ToastQueue] {
        func queue() -> ToastQueue { ToastQueue(autoAdvance: false, announce: { _ in }, isVoiceOverRunning: { true }) }
        let done = queue()
        done.show("BigBuckBunny-1080p.mp4 finished", kind: .success)
        let undo = queue()
        undo.show("Removed 2 downloads", kind: .info, action: Toast.Action(title: "Undo") {})
        undo.show("Paused all downloads", kind: .success)
        undo.show("Speed limit on · Medium", kind: .success)
        let failed = queue()
        failed.show("Fedora-Workstation-40.iso failed: FTP server closed the connection", kind: .error)
        let warning = queue()
        warning.show("Nothing to pause", kind: .warning)
        return [done, undo, failed, warning]
    }

    var body: some View {
        VStack(spacing: 14) {
            ForEach(Array(queues.enumerated()), id: \.offset) { _, queue in
                ToastOverlay(queue: queue, bottomPadding: 0)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// The status bar with its popovers laid out underneath (popovers can't be captured in place).
private struct StatusBarGallery: View {
    let model: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            StatusBar()
            HStack(alignment: .top, spacing: 24) {
                GlobalSpeedHistoryPopover(telemetry: model.telemetry)
                    .padding(14)
                    .background(Studio.Palette.cardRaised, in: RoundedRectangle(cornerRadius: 13))
                StatusTransfersPopover {}
                    .clipShape(RoundedRectangle(cornerRadius: 13))
                SpeedCapPopover()
                    .background(Studio.Palette.cardRaised, in: RoundedRectangle(cornerRadius: 13))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(Studio.Palette.canvas)
    }
}
#endif
