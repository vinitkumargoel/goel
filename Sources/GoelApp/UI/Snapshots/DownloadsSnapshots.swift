#if DEBUG
import SwiftUI
import GoelCore

/// The Downloads area's snapshots. Owned by the Downloads area agent: add entries here only, named
/// `downloads.<screen>`, e.g. `StudioSnapshotEntry("downloads.example", width: 900) { context in … }`.
/// Render them with `GoelDownloader --studio-snapshots <outdir> --only downloads.`
@MainActor
enum DownloadsSnapshots {
    static var entries: [StudioSnapshotEntry] {
        boards + lists + menus + states
    }

    private static var boards: [StudioSnapshotEntry] {
        [
            StudioSnapshotEntry("downloads.board", width: 1212, height: 900) { context in
                content(prepare(context), layout: .board)
            },
            StudioSnapshotEntry("downloads.board.narrow", width: 860, height: 900) { context in
                content(prepare(context), layout: .board)
            },
            StudioSnapshotEntry("downloads.board.grouped", width: 1212, height: 820) { context in
                content(prepare(context, grouping: .type), layout: .board)
            },
            StudioSnapshotEntry("downloads.board.multiselect", width: 1212, height: 560) { context in
                let model = prepare(context)
                model.selection = [StudioSampleData.ID.ubuntu.uuid, StudioSampleData.ID.cosmos.uuid,
                                   StudioSampleData.ID.backup.uuid]
                return content(model, layout: .board)
            },
        ]
    }

    private static var lists: [StudioSnapshotEntry] {
        [
            StudioSnapshotEntry("downloads.list.regular", width: 1212, height: 820) { context in
                content(prepare(context, tasks: statesTasks), layout: .list)
            },
            StudioSnapshotEntry("downloads.list.compact", width: 1212, height: 640) { context in
                content(prepare(context, tasks: statesTasks), layout: .list, density: .compact)
            },
            StudioSnapshotEntry("downloads.list.narrow", width: 760, height: 640) { context in
                content(prepare(context), layout: .list)
            },
            StudioSnapshotEntry("downloads.list.extras", width: 1500, height: 520) { context in
                content(prepare(context), layout: .list,
                        columnsRaw: "size,status,speed,added,eta,ratio,peers,host,tags,protocol")
            },
            StudioSnapshotEntry("downloads.list.grouped", width: 1212, height: 820) { context in
                content(prepare(context, tasks: statesTasks, grouping: .date), layout: .list)
            },
        ]
    }

    private static var menus: [StudioSnapshotEntry] {
        [
            StudioSnapshotEntry("downloads.menu.columns", width: 300) { _ in
                menuCard(DownloadsHeaderMenus.columnNodes(columnsRaw: .constant(""), density: .constant(.regular)))
            },
            StudioSnapshotEntry("downloads.menu.context", width: 620) { context in
                let model = prepare(context)
                return HStack(alignment: .top, spacing: 0) {
                    menuCard(builder(context.task(.ubuntu), model).nodes(summary: nil))
                    menuCard(builder(context.task(.bunny), model).nodes(summary: nil))
                }
            },
            StudioSnapshotEntry("downloads.menu.selection", width: 620) { context in
                let model = prepare(context)
                let three = [context.task(.ubuntu), context.task(.imagenet), context.task(.fedora)]
                return HStack(alignment: .top, spacing: 0) {
                    menuCard(builder(context.task(.ubuntu), model).nodes(summary: DownloadSelectionSummary(three)))
                    menuCard(builder(missingFile, model).nodes(summary: nil))
                }
            },
            StudioSnapshotEntry("downloads.menu.header", width: 900) { context in
                let model = prepare(context)
                return HStack(alignment: .top, spacing: 0) {
                    menuCard(DownloadsHeaderMenus.sortNodes(model), width: 220)
                    menuCard(DownloadsHeaderMenus.groupNodes(model), width: 180)
                    menuCard(DownloadsHeaderMenus.selectNodes(model), width: 200)
                    menuCard(DownloadsHeaderMenus.typeNodes(model), width: 200)
                }
            },
        ]
    }

    private static var states: [StudioSnapshotEntry] {
        [
            StudioSnapshotEntry("downloads.cards.states", width: 1120) { _ in
                DownloadsCardStatesSheet()
            },
            StudioSnapshotEntry("downloads.nomatch", width: 1000, height: 460) { context in
                content(prepare(context, filter: .type(.audio), search: "host:archive.org mozart"), layout: .board)
            },
            StudioSnapshotEntry("downloads.filtered", width: 1000, height: 520) { context in
                content(prepare(context, filter: .tag("linux")), layout: .list)
            },
        ]
    }

    // MARK: - Helpers

    /// Resets the shared sample model to a known state. Grouping is written to defaults by the
    /// model, so turning it back off also removes the key again.
    private static func prepare(_ context: StudioSnapshotContext, tasks: [DownloadTask]? = nil,
                                grouping: ListGrouping = .none, filter: SidebarFilter = .all,
                                search: String = "") -> AppViewModel {
        let model = context.model
        if let tasks { model.installSampleSnapshot(tasks, selecting: StudioSampleData.ID.ubuntu.uuid) }
        model.filter = filter
        model.search = search
        model.sortKey = .index
        model.sortAscending = true
        if model.grouping != grouping {
            model.grouping = grouping
            if grouping == .none { UserDefaults.standard.removeObject(forKey: AppViewModel.groupingKey) }
        }
        return model
    }

    private static func content(_ model: AppViewModel, layout: DownloadsLayout,
                                density: ListDensity = .regular, columnsRaw: String = "") -> some View {
        DownloadsContent(layout: .constant(layout), columnsRaw: .constant(columnsRaw), density: .constant(density))
            .studioSampleEnvironment(model)
    }

    private static func builder(_ task: DownloadTask, _ model: AppViewModel) -> DownloadMenuBuilder {
        DownloadMenuBuilder(task: task, context: DownloadItemContext(vm: model), vm: model,
                            quickLook: QuickLookAction(item: nil))
    }

    private static func menuCard(_ nodes: [DownloadMenuNode], width: CGFloat = 270) -> some View {
        DownloadStudioMenu(nodes: nodes, width: width)
            .studioSurface(.raised, radius: Studio.Radius.tile, elevation: .floating)
            .padding(Studio.Space.xl)
    }

    /// The sample queue plus the two states it lacks: verifying and a missing file.
    static var statesTasks: [DownloadTask] {
        let arch = DownloadTask(
            source: .url(URL(string: "https://geo.mirror.pkgbuild.com/iso/archlinux-2026.10.01-x86_64.iso")!),
            name: "archlinux-2026.10.01-x86_64.iso",
            saveDirectory: "\(StudioSampleData.downloads)/Disc images",
            totalBytes: 1_200_000_000, bytesDownloaded: 1_200_000_000,
            status: .verifying, addedAt: Date().addingTimeInterval(-50 * 60))
        return StudioSampleData.tasks + [arch, missingFile]
    }

    static var missingFile: DownloadTask {
        var blender = DownloadTask(
            source: .url(URL(string: "https://download.blender.org/release/Blender-4.2.3-macos-arm64.dmg")!),
            name: "Blender-4.2.3-macos-arm64.dmg",
            saveDirectory: "\(StudioSampleData.downloads)/Apps",
            totalBytes: 398_000_000, bytesDownloaded: 398_000_000,
            status: .completed, addedAt: Date().addingTimeInterval(-26 * 3600))
        blender.completedAt = Date().addingTimeInterval(-25 * 3600)
        blender.fileMissing = true
        return blender
    }
}

/// Every card state side by side, the mockup's "same states as cards" strip.
private struct DownloadsCardStatesSheet: View {
    var body: some View {
        let model = StudioSampleData.makeViewModel()
        let context = DownloadItemContext(vm: model)
        let tasks = DownloadsSnapshots.statesTasks
        let large = tasks.filter { BoardCardStyle(task: $0) == .large }
        let compact = tasks.filter { BoardCardStyle(task: $0) == .compact }
        return VStack(alignment: .leading, spacing: Studio.Space.l) {
            HStack(alignment: .top, spacing: Studio.Space.laneGap) {
                ForEach(large) { task in
                    card(task, model: model, context: context, selected: task.id == StudioSampleData.ID.ubuntu.uuid)
                        .frame(width: 252)
                }
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Studio.Space.cardGap),
                                GridItem(.flexible(), spacing: Studio.Space.cardGap)],
                      alignment: .leading, spacing: Studio.Space.cardGap) {
                ForEach(compact) { task in
                    card(task, model: model, context: context, selected: false)
                }
            }
        }
        .padding(Studio.Space.xl)
        .studioSampleEnvironment(model)
    }

    private func card(_ task: DownloadTask, model: AppViewModel, context: DownloadItemContext,
                      selected: Bool) -> DownloadBoardCard {
        DownloadBoardCard(task: task, queueRank: model.queueRanks[task.id] ?? task.queuePosition,
                          isSelected: selected,
                          speed: SpeedSample(down: task.downloadSpeed, up: task.uploadSpeed),
                          summary: nil, context: context, vm: model)
    }
}
#endif
