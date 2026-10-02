#if DEBUG
import SwiftUI
import GoelCore

/// The Windows area's snapshots: menu bar, palette, history, onboarding, RSS, statistics and
/// speed popovers, torrent, player, drop basket, conversions dock and the auto-shutdown countdown.
/// Render them with `GoelDownloader --studio-snapshots <outdir> --only windows.`
@MainActor
enum WindowsSnapshots {
    static var entries: [StudioSnapshotEntry] {
        menuBar + palette + history + onboarding + rss + speed + overlays + utilities
    }

    // MARK: Menu bar

    private static var menuBar: [StudioSnapshotEntry] {
        [
            StudioSnapshotEntry("windows.menubar", width: MenuBarPopover.width) { context in
                let model = context.model
                MenuBarPopover(center: model.mediaJobs, commands: model.commandState,
                               transfersOverride: SFTPSampleFixture.activeTransfers(),
                               jobsOverride: [WindowsSampleData.job(.running)])
                    .studioSampleEnvironment(model)
            },
            StudioSnapshotEntry("windows.menubar.sections", width: MenuBarPopover.width) { context in
                let model = context.model
                let _ = model.installSampleSnapshot([StudioSampleData.task(.ubuntu), StudioSampleData.task(.bunny),
                                                     StudioSampleData.task(.boardPack)], selecting: nil)
                MenuBarPopover(center: model.mediaJobs, commands: model.commandState,
                               transfersOverride: SFTPSampleFixture.activeTransfers(),
                               jobsOverride: [WindowsSampleData.job(.running)])
                    .studioSampleEnvironment(model)
            },
            StudioSnapshotEntry("windows.menubar.countdown", width: MenuBarPopover.width) { context in
                let model = context.model
                MenuBarPopover(center: model.mediaJobs, commands: model.commandState,
                               transfersOverride: [], jobsOverride: [],
                               countdownOverride: WindowsSampleData.countdown())
                    .studioSampleEnvironment(model)
            },
            StudioSnapshotEntry("windows.menubar.empty", width: MenuBarPopover.width) { context in
                let model = context.model
                let _ = model.installSampleSnapshot([], selecting: nil)
                MenuBarPopover(center: model.mediaJobs, commands: model.commandState,
                               transfersOverride: [], jobsOverride: [])
                    .studioSampleEnvironment(model)
            },
        ]
    }

    // MARK: Command palette

    private static var palette: [StudioSnapshotEntry] {
        [
            StudioSnapshotEntry("windows.palette", width: 640) { context in
                CommandPalette().studioSampleEnvironment(context.model)
            },
            StudioSnapshotEntry("windows.palette.search", width: 640) { context in
                CommandPalette(query: "pa").studioSampleEnvironment(context.model)
            },
            StudioSnapshotEntry("windows.palette.nomatch", width: 640) { context in
                CommandPalette(query: "zzqx").studioSampleEnvironment(context.model)
            },
        ]
    }

    // MARK: History

    private static var history: [StudioSnapshotEntry] {
        [
            StudioSnapshotEntry("windows.history", width: 1100, height: 720) { context in
                let items = WindowsSampleData.historyItems
                HistoryView(items: items, selection: [items[0].id]).studioSampleEnvironment(context.model)
            },
            StudioSnapshotEntry("windows.history.narrow", width: 720, height: 560) { context in
                let items = WindowsSampleData.historyItems
                HistoryView(items: items, selection: [items[1].id, items[2].id, items[3].id])
                    .studioSampleEnvironment(context.model)
            },
            StudioSnapshotEntry("windows.history.empty", width: 720, height: 460) { context in
                HistoryView(items: []).studioSampleEnvironment(context.model)
            },
            StudioSnapshotEntry("windows.history.nomatch", width: 720, height: 460) { context in
                HistoryView(items: WindowsSampleData.historyItems, search: "zzqx").studioSampleEnvironment(context.model)
            },
        ]
    }

    // MARK: Onboarding

    private static var onboarding: [StudioSnapshotEntry] {
        let size = OnboardingView.size
        return [
            StudioSnapshotEntry("windows.onboarding.welcome", width: size.width, height: size.height) { context in
                OnboardingView(step: .welcome).studioSampleEnvironment(context.model)
            },
            StudioSnapshotEntry("windows.onboarding.folder", width: size.width, height: size.height) { context in
                OnboardingView(step: .saveFolder).studioSampleEnvironment(context.model)
            },
            StudioSnapshotEntry("windows.onboarding.browser", width: size.width, height: size.height) { context in
                OnboardingView(step: .browser, browserChoice: .chrome).studioSampleEnvironment(context.model)
            },
            StudioSnapshotEntry("windows.onboarding.browser.safari", width: size.width, height: size.height) { context in
                OnboardingView(step: .browser, browserChoice: .safari).studioSampleEnvironment(context.model)
            },
            StudioSnapshotEntry("windows.onboarding.clipboard", width: size.width, height: size.height) { context in
                OnboardingView(step: .clipboard).studioSampleEnvironment(context.model)
            },
            StudioSnapshotEntry("windows.onboarding.ready", width: size.width, height: size.height) { context in
                OnboardingView(step: .ready, notificationPermission: .notAsked).studioSampleEnvironment(context.model)
            },
        ]
    }

    // MARK: RSS

    private static var rss: [StudioSnapshotEntry] {
        [
            StudioSnapshotEntry("windows.rss", width: 1000, height: 640) { context in
                RSSReaderView(preview: WindowsSampleData.rssData()).studioSampleEnvironment(context.model)
            },
            StudioSnapshotEntry("windows.rss.noselection", width: 1000, height: 520) { context in
                var data = WindowsSampleData.rssData(selectArticle: false)
                let _ = data.errors[WindowsSampleData.linuxFeed.id] = "Couldn’t load the feed — the server answered 503"
                RSSReaderView(preview: data).studioSampleEnvironment(context.model)
            },
            StudioSnapshotEntry("windows.rss.empty", width: 1000, height: 480) { context in
                RSSReaderView(preview: RSSReaderData(feeds: [])).studioSampleEnvironment(context.model)
            },
            StudioSnapshotEntry("windows.rss.rule", width: 470) { context in
                RSSRuleSheet(original: WindowsSampleData.linuxFeed, previewItems: WindowsSampleData.linuxArticles)
                    .studioSampleEnvironment(context.model)
            },
            StudioSnapshotEntry("windows.rss.add", width: 470) { context in
                RSSRuleSheet(original: nil).studioSampleEnvironment(context.model)
            },
        ]
    }

    // MARK: Statistics and speed

    private static var speed: [StudioSnapshotEntry] {
        [
            StudioSnapshotEntry("windows.stats", width: 600) { context in
                StatsView(stats: WindowsSampleData.stats).studioSampleEnvironment(context.model)
            },
            StudioSnapshotEntry("windows.speed.popover", width: 360) { context in
                GlobalSpeedHistoryPopover(telemetry: context.model.telemetry)
            },
            StudioSnapshotEntry("windows.speed.sparklines", width: 360) { context in
                VStack(alignment: .leading, spacing: Studio.Space.ml) {
                    HStack(spacing: Studio.Space.m) {
                        GlobalSpeedSparkline(direction: .down)
                        GlobalSpeedSparkline(direction: .up)
                    }
                    TaskSpeedGraph(taskID: StudioSampleData.ID.ubuntu.uuid)
                    TaskSpeedGraph(taskID: StudioSampleData.ID.debian.uuid)
                    SparklineView(values: [1, 3, 2, 5, 4, 6, 5, 8], tint: Studio.Palette.upload)
                        .frame(height: 30)
                }
                .padding(Studio.Space.xl)
                .studioSampleEnvironment(context.model)
            },
            StudioSnapshotEntry("windows.speedcap", width: 300) { context in
                SpeedCapPopover().studioSampleEnvironment(context.model)
            },
        ]
    }

    // MARK: Overlays

    private static var overlays: [StudioSnapshotEntry] {
        [
            StudioSnapshotEntry("windows.jobs", width: 380) { context in
                MediaJobStack(jobs: [WindowsSampleData.job(.running), WindowsSampleData.job(.finished),
                                     WindowsSampleData.job(.failed), WindowsSampleData.job(.stalled),
                                     WindowsSampleData.job(.queued), WindowsSampleData.job(.queued)],
                              center: context.model.mediaJobs)
                    .padding(.top, Studio.Space.xl)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            },
            StudioSnapshotEntry("windows.jobs.stopping", width: 380) { context in
                MediaJobStack(jobs: [WindowsSampleData.job(.queued), WindowsSampleData.job(.cancelling),
                                     WindowsSampleData.job(.stuck), WindowsSampleData.job(.cancelled)],
                              center: context.model.mediaJobs)
                    .padding(.top, Studio.Space.xl)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            },
            StudioSnapshotEntry("windows.countdown", width: 760, height: 420) { _ in
                ZStack {
                    Studio.Palette.scrim
                    HStack(alignment: .top, spacing: Studio.Space.xl) {
                        AutoShutdownCountdownCard(intent: .sleep, remaining: 30, total: 60, onCancel: {}, onNow: {})
                        AutoShutdownCountdownCard(intent: .quit, remaining: 12, total: 60, onCancel: {}, onNow: {})
                    }
                }
            },
            StudioSnapshotEntry("windows.countdown.shutdown", width: 380) { _ in
                AutoShutdownCountdownCard(intent: .shutdown, remaining: 1, total: 60, onCancel: {}, onNow: {})
                    .padding(24)
            },
        ]
    }

    // MARK: Torrent, player, basket

    private static var utilities: [StudioSnapshotEntry] {
        let trackers = "udp://tracker.opentrackr.org:1337/announce\nudp://open.stealth.si:80/announce"
        let recordings = "/Users/sample/Music/Field Recordings Vol. 3"
        let summary = TorrentSourceSummary(isFolder: true, fileCount: 24, totalBytes: 1_300_000_000)
        let movie = AppViewModel.PlayerItem(url: URL(fileURLWithPath: "/tmp/goel-snapshot-missing.mp4"),
                                            title: "BigBuckBunny-1080p.mp4")
        let mkv = AppViewModel.PlayerItem(url: URL(fileURLWithPath: "/tmp/goel-snapshot-missing.mkv"),
                                          title: "Cosmos.S01E04.2160p.HDR.mkv")
        return [
            StudioSnapshotEntry("windows.torrent", width: 580) { context in
                CreateTorrentView(onClose: {}).studioSampleEnvironment(context.model)
            },
            StudioSnapshotEntry("windows.torrent.filled", width: 580) { context in
                CreateTorrentView(onClose: {}, sourcePath: recordings, summary: summary, trackers: trackers,
                                  comment: "Recorded in Ladakh, 2026",
                                  error: "Couldn’t write the torrent: the disk is full.")
                    .studioSampleEnvironment(context.model)
            },
            StudioSnapshotEntry("windows.torrent.hashing", width: 580) { context in
                CreateTorrentView(onClose: {}, sourcePath: recordings, summary: summary, progress: 0.64)
                    .studioSampleEnvironment(context.model)
            },
            StudioSnapshotEntry("windows.player.unplayable", width: 900, height: 420) { context in
                InAppPlayerView(item: mkv, failure: L10n.t("This file’s video or audio track uses a codec macOS can’t decode."),
                                onClose: {})
                    .studioSampleEnvironment(context.model)
            },
            StudioSnapshotEntry("windows.player", width: 900, height: 420) { context in
                InAppPlayerView(item: movie, onClose: {}).studioSampleEnvironment(context.model)
            },
            StudioSnapshotEntry("windows.player.empty", width: 600, height: 360) { context in
                PlayerWindow().studioSampleEnvironment(context.model)
            },
            StudioSnapshotEntry("windows.basket", width: DropBasketView.width, height: DropBasketView.height) { context in
                DropBasketView(vm: context.model).studioSampleEnvironment(context.model)
            },
            StudioSnapshotEntry("windows.basket.added", width: DropBasketView.width,
                                height: DropBasketView.height) { context in
                DropBasketView(vm: context.model, addedCount: 3, isTargeted: true)
                    .studioSampleEnvironment(context.model)
            },
        ]
    }
}
#endif
