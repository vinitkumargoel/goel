#if DEBUG
import SwiftUI
import GoelCore

/// The Detail area's snapshots: the floating side sheet in every sample state and tab, the queue
/// overview, multi-select, the recovery and tracker sheets, and the bottom dock.
/// Render them with `GoelDownloader --studio-snapshots <outdir> --only detail.`
@MainActor
enum DetailSnapshots {
    static var entries: [StudioSnapshotEntry] {
        sheetEntries + sheetDialogEntries + dockEntries
    }

    // MARK: Side sheet

    private static var sheetEntries: [StudioSnapshotEntry] {
        [
            side("detail.http", select: .ubuntu, tab: .overview, tasks: richTasks),
            side("detail.bt", select: .cosmos, tab: .overview, tasks: richTasks),
            side("detail.seeding", select: .debian, tab: .overview),
            side("detail.paused", select: .imagenet, tab: .overview),
            side("detail.metadata", select: .magnet, tab: .overview),
            side("detail.completed", select: .bunny, tab: .overview),
            side("detail.missing", select: .boardPack, tab: .overview, tasks: missingTasks),
            side("detail.failed", select: .fedora, tab: .overview),
            side("detail.failed-link", select: .fedora, tab: .overview, tasks: failed404Tasks),
            side("detail.files", select: .cosmos, tab: .files),
            side("detail.files-metadata", select: .magnet, tab: .files),
            side("detail.network-bt", select: .cosmos, tab: .network, tasks: richTasks),
            side("detail.network-metadata", select: .magnet, tab: .network),
            side("detail.network-http", select: .ubuntu, tab: .network, tasks: richTasks),
            side("detail.network-single", select: .imagenet, tab: .network),
            StudioSnapshotEntry("detail.queue", width: sheetWidth + 28, height: sheetHeight + 28) { _ in
                floating(queueModel())
            },
            StudioSnapshotEntry("detail.multi", width: sheetWidth + 28, height: sheetHeight + 28) { _ in
                floating(multiModel())
            },
        ]
    }

    // MARK: Dialogs

    private static var sheetDialogEntries: [StudioSnapshotEntry] {
        [
            StudioSnapshotEntry("detail.sheet.update-link", width: 470) { _ in
                UpdateLinkSheet(task: StudioSampleData.task(.fedora))
                    .studioSampleEnvironment(StudioSampleData.makeViewModel(selecting: .fedora))
            },
            StudioSnapshotEntry("detail.sheet.cookies", width: 470) { _ in
                AttachCookiesSheet(task: StudioSampleData.task(.imagenet))
                    .studioSampleEnvironment(StudioSampleData.makeViewModel(selecting: .imagenet))
            },
            StudioSnapshotEntry("detail.sheet.change-folder", width: 470) { _ in
                ChangeFolderSheet(task: StudioSampleData.task(.imagenet))
                    .studioSampleEnvironment(StudioSampleData.makeViewModel(selecting: .imagenet))
            },
            StudioSnapshotEntry("detail.sheet.tracker-add", width: 470) { _ in
                TrackerEditSheet(mode: .add, taskID: StudioSampleData.ID.cosmos.uuid)
                    .studioSampleEnvironment(StudioSampleData.makeViewModel(selecting: .cosmos))
            },
            StudioSnapshotEntry("detail.sheet.tracker-edit", width: 470) { _ in
                TrackerEditSheet(mode: .edit("udp://open.stealth.si:80/announce"), taskID: StudioSampleData.ID.cosmos.uuid)
                    .studioSampleEnvironment(StudioSampleData.makeViewModel(selecting: .cosmos))
            },
        ]
    }

    // MARK: Bottom dock

    private static var dockEntries: [StudioSnapshotEntry] {
        [
            StudioSnapshotEntry("detail.dock", width: 1180, height: 300) { _ in
                dock(model(select: .ubuntu, tab: .overview, tasks: richTasks))
            },
            StudioSnapshotEntry("detail.dock.narrow", width: 860, height: 300) { _ in
                dock(model(select: .cosmos, tab: .network, tasks: richTasks, forcedBottom: true))
            },
            StudioSnapshotEntry("detail.dock.600", width: 600, height: 300) { _ in
                dock(model(select: .ubuntu, tab: .overview, tasks: richTasks, forcedBottom: true))
            },
            StudioSnapshotEntry("detail.dock.600-failed", width: 600, height: 300) { _ in
                dock(model(select: .fedora, tab: .overview, forcedBottom: true))
            },
            StudioSnapshotEntry("detail.dock.600-network", width: 600, height: 300) { _ in
                dock(model(select: .cosmos, tab: .network, tasks: richTasks, forcedBottom: true))
            },
            StudioSnapshotEntry("detail.dock.600-queue", width: 600, height: 300) { _ in
                dock(queueModel())
            },
            StudioSnapshotEntry("detail.dock.600-multi", width: 600, height: 300) { _ in
                dock(multiModel())
            },
            StudioSnapshotEntry("detail.dock.failed", width: 1180, height: 300) { _ in
                dock(model(select: .fedora, tab: .overview))
            },
            StudioSnapshotEntry("detail.dock.queue", width: 1180, height: 300) { _ in
                dock(queueModel())
            },
            StudioSnapshotEntry("detail.dock.multi", width: 1180, height: 300) { _ in
                dock(multiModel())
            },
        ]
    }

    // MARK: Helpers

    private static let sheetWidth: CGFloat = 372
    private static let sheetHeight: CGFloat = 900

    private static func side(_ name: String, select: StudioSampleData.ID, tab: DetailTab,
                             tasks: (() -> [DownloadTask])? = nil) -> StudioSnapshotEntry {
        StudioSnapshotEntry(name, width: sheetWidth + 28, height: sheetHeight + 28) { _ in
            floating(model(select: select, tab: tab, tasks: tasks))
        }
    }

    private static func model(select: StudioSampleData.ID, tab: DetailTab,
                              tasks: (() -> [DownloadTask])? = nil, forcedBottom: Bool = false) -> AppViewModel {
        let model = StudioSampleData.makeViewModel(selecting: select)
        if let tasks { model.installSampleSnapshot(tasks(), selecting: select.uuid) }
        model.detailTab = tab
        model.detailDockForcedBottom = forcedBottom
        return model
    }

    private static func queueModel() -> AppViewModel {
        let model = StudioSampleData.makeViewModel(selecting: nil)
        model.selection = []
        model.primarySelection = nil
        model.detailDockForcedBottom = false
        return model
    }

    private static func multiModel() -> AppViewModel {
        let model = StudioSampleData.makeViewModel(selecting: .ubuntu)
        model.selection = [StudioSampleData.ID.ubuntu.uuid, StudioSampleData.ID.cosmos.uuid,
                           StudioSampleData.ID.backup.uuid, StudioSampleData.ID.imagenet.uuid]
        model.primarySelection = StudioSampleData.ID.cosmos.uuid
        model.detailDockForcedBottom = false
        return model
    }

    /// The sheet as MainWindow floats it: sheet surface, sheet radius, floating shadow, on canvas.
    private static func floating(_ model: AppViewModel) -> some View {
        DetailPanelView()
            .frame(width: sheetWidth, height: sheetHeight)
            .studioSurface(.sheet, radius: Studio.Radius.sheet, elevation: .floating)
            .padding(14)
            .background(Studio.Palette.canvas)
            .studioSampleEnvironment(model)
    }

    private static func dock(_ model: AppViewModel) -> some View {
        VStack(spacing: 0) {
            DetailPanelResizeHandle(storedHeight: .constant(DetailPanelHeight.standard), liveHeight: .constant(nil),
                                    displayedHeight: DetailPanelHeight.standard)
            DetailBottomPanel()
        }
        .background(Studio.Palette.canvas)
        .studioSampleEnvironment(model)
    }

    /// The ubuntu ISO with what an HTTP server tells us filled in: range support, ETag, MIME,
    /// a published checksum, a referer and cookies, so every HTTP fact shows.
    private static func richTasks() -> [DownloadTask] {
        StudioSampleData.tasks.map { task in
            if task.id == StudioSampleData.ID.cosmos.uuid { return withPeers(task) }
            guard task.id == StudioSampleData.ID.ubuntu.uuid else { return task }
            var copy = task
            copy.remoteInfo = RemoteInfo(server: "Apache", etag: "\"12c0a4000-61f2b1c8\"",
                                         acceptRanges: true, mimeType: "application/x-iso9660-image")
            copy.expectedChecksum = Checksum(algorithm: .sha256, value: String(repeating: "a", count: 64))
            copy.resumeData = Data([1])
            copy.referer = "https://ubuntu.com/download/desktop"
            copy.cookieSource = .browser
            let progress: [Double] = [1, 1, 0.86, 0.71, 0.58, 0.44, 0.22, 0.15]
            copy.connections = (copy.connections ?? []).enumerated().map { index, connection in
                var segment = connection
                segment.adapterLabel = index.isMultiple(of: 2) ? "en0" : "en5"
                segment.progress = progress[index % progress.count]
                return segment
            }
            return copy
        }
    }

    /// The Cosmos torrent with a handful of live peers on two adapters.
    private static func withPeers(_ task: DownloadTask) -> DownloadTask {
        var copy = task
        let mb = 1_000_000.0
        copy.connections = [
            TaskConnection(id: "p1", label: "185.21.44.14", detail: "qBittorrent 5.0",
                           downloadSpeed: 4.1 * mb, progress: 1, adapterLabel: "en0"),
            TaskConnection(id: "p2", label: "91.134.12.2", detail: "Transmission 4.0",
                           downloadSpeed: 3.6 * mb, progress: 1, adapterLabel: "en0"),
            TaskConnection(id: "p3", label: "2a01:4f8::7c", detail: "libtorrent 2.0",
                           downloadSpeed: 2.2 * mb, uploadSpeed: 210_000, progress: 0.72, adapterLabel: "en5"),
            TaskConnection(id: "p4", label: "62.210.9.88", detail: "peer",
                           downloadSpeed: 1.4 * mb, uploadSpeed: 180_000, progress: 0.55, adapterLabel: "en0"),
        ]
        return copy
    }

    private static func missingTasks() -> [DownloadTask] {
        StudioSampleData.tasks.map { task in
            guard task.id == StudioSampleData.ID.boardPack.uuid else { return task }
            var copy = task
            copy.fileMissing = true
            return copy
        }
    }

    private static func failed404Tasks() -> [DownloadTask] {
        StudioSampleData.tasks.map { task in
            guard task.id == StudioSampleData.ID.fedora.uuid else { return task }
            var copy = task
            if let url = URL(string: "https://download.fedoraproject.org/pub/fedora/40/Fedora-Workstation-40.iso") {
                copy.source = .url(url)
            }
            copy.status = .failed(.httpStatus(404))
            return copy
        }
    }
}
#endif
