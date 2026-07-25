import SwiftUI
import WidgetKit

// MARK: - Timeline

/// One reload's worth of state. Nothing here changes faster than the timeline that carries it.
struct GoelEntry: TimelineEntry {
    var date: Date
    var snapshot: SharedSnapshot
    /// Recent transfer rates for the `FASTEST` sparkline. Empty for live entries — see
    /// ``GoelSnapshotProvider``.
    var speedHistory: [Double]

    var summary: WidgetSummary { WidgetSummary(snapshot: snapshot) }
}

/// The one provider every Goel widget uses.
///
/// **The budget is the design constraint.** WidgetKit grants tens of timeline reloads per day,
/// not thousands, and PRD §6.5 requires that a widget never contradict the Live Activity by more
/// than one refresh interval. Both are satisfied the same way: emit a *single* entry holding
/// aggregate, slow-moving state and ask for the next reload in fifteen minutes with
/// `.after(_:)`. `.atEnd` with a short entry list is the classic way to burn the budget by
/// lunchtime and then show nothing at all for the rest of the day.
///
/// The app pushes fresher data by calling `WidgetCenter.reloadAllTimelines()` when it has
/// execution time — `DownloadStore` already does that, rate limited to once every 15 s.
struct GoelSnapshotProvider: TimelineProvider {

    /// How long until the system should ask again.
    static let refreshInterval: TimeInterval = 15 * 60

    /// The fixture `placeholder` and `snapshot` render. Both must draw instantly and look real:
    /// the widget picker, the gallery, and the redacted first paint all go through them.
    let sample: SharedSnapshot
    let sampleHistory: [Double]

    init(sample: SharedSnapshot, sampleHistory: [Double] = []) {
        self.sample = sample
        self.sampleHistory = sampleHistory
    }

    func placeholder(in context: Context) -> GoelEntry {
        GoelEntry(date: Date(), snapshot: sample, speedHistory: sampleHistory)
    }

    func getSnapshot(in context: Context, completion: @escaping (GoelEntry) -> Void) {
        // In the gallery/picker show the fixture; on the real Home Screen show the truth.
        let snapshot = context.isPreview ? sample : SharedSnapshot.read()
        let history = context.isPreview ? sampleHistory : []
        completion(GoelEntry(date: Date(), snapshot: snapshot, speedHistory: history))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GoelEntry>) -> Void) {
        let now = Date()
        // Live entries carry no speed history: `SharedSnapshot` is a point sample and a widget
        // that invented a trend line would be doing precisely what §6.5 forbids.
        let entry = GoelEntry(date: now, snapshot: SharedSnapshot.read(), speedHistory: [])
        completion(Timeline(
            entries: [entry],
            policy: .after(now.addingTimeInterval(Self.refreshInterval))
        ))
    }
}

// MARK: - Small · summary

/// `Goel°` · the active count · `active · 21.4 GB left` · aggregate bar.
/// `visual.html` frame 7, top-left.
struct GoelSummaryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "dev.goel.ios.widget.summary",
            provider: GoelSnapshotProvider(sample: WidgetSample.homeScreen)
        ) { entry in
            HomeSummaryView(summary: entry.summary)
                .widgetURL(GoelWidgetLink.queue)
                .containerBackground(for: .widget) { WidgetSurface() }
        }
        .configurationDisplayName("Downloads")
        .description("How much is still coming down, at a glance.")
        .supportedFamilies([.systemSmall])
        // The mockup's 14 pt inset is drawn by the view itself, so the system margin is off.
        .contentMarginsDisabled()
    }
}

// MARK: - Small · fastest

/// `FASTEST` · `48.2 MB/s` · the filename · a mini sparkline. `visual.html` frame 7, top-right.
struct GoelFastestWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "dev.goel.ios.widget.fastest",
            provider: GoelSnapshotProvider(
                sample: WidgetSample.homeScreen,
                sampleHistory: WidgetSample.speedHistory
            )
        ) { entry in
            let fastest = entry.snapshot.top.max { $0.speed < $1.speed }
            HomeFastestView(
                speed: fastest?.speed ?? 0,
                filename: fastest?.filename,
                history: entry.speedHistory
            )
            .widgetURL(fastest.flatMap { GoelWidgetLink.download(id: $0.id) } ?? GoelWidgetLink.queue)
            .containerBackground(for: .widget) { WidgetSurface() }
        }
        .configurationDisplayName("Fastest")
        .description("The quickest transfer in the queue.")
        .supportedFamilies([.systemSmall])
        .contentMarginsDisabled()
    }
}

// MARK: - Medium · queue

/// `QUEUE` · three rows of name + percent, each with its own bar. `visual.html` frame 7, bottom.
struct GoelQueueWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "dev.goel.ios.widget.queue",
            provider: GoelSnapshotProvider(sample: WidgetSample.homeScreen)
        ) { entry in
            HomeQueueView(items: entry.snapshot.top)
                .widgetURL(GoelWidgetLink.queue)
                .containerBackground(for: .widget) { WidgetSurface() }
        }
        .configurationDisplayName("Queue")
        .description("The top of the download queue.")
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}
