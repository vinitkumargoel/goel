import SwiftUI
import WidgetKit

/// The Lock Screen accessories — `visual.html` frame 5, the three chips under the clock.
///
/// **These are timeline widgets, not live ones**, and the distinction is the whole point of
/// PRD §6.5's table. The Live Activity below them owns liveness; these carry aggregate,
/// slow-moving truth on a 15-minute cadence so the two can never be seen to disagree by more
/// than one refresh interval. Nothing here reads a per-download byte counter.
///
/// One widget kind serves all three families, which is what puts a single "Goel°" row in the
/// Lock Screen picker instead of three.
struct GoelAccessoryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "dev.goel.ios.widget.accessory",
            provider: GoelSnapshotProvider(sample: WidgetSample.lockScreen)
        ) { entry in
            AccessoryEntryView(entry: entry)
                .widgetURL(GoelWidgetLink.queue)
        }
        .configurationDisplayName("Goel°")
        .description("Aggregate download progress.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

/// The second circular accessory in the mockup: `4 / ACTIVE`, no ring.
/// A separate kind so both circulars can sit on the Lock Screen at once, as frame 5 draws them.
struct GoelActiveCountWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "dev.goel.ios.widget.active",
            provider: GoelSnapshotProvider(sample: WidgetSample.lockScreen)
        ) { entry in
            AccessoryActiveCountView(summary: entry.summary)
                .widgetURL(GoelWidgetLink.queue)
        }
        .configurationDisplayName("Active downloads")
        .description("How many transfers are running.")
        .supportedFamilies([.accessoryCircular])
    }
}

/// Family dispatch. Each branch honours `\.widgetRenderingMode` internally — the Lock Screen
/// renders accessories in a vibrant monochrome mode, where a hardcoded ember is either dropped
/// or rendered as mud, so the tint is only applied when the mode is `.fullColor`.
private struct AccessoryEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: GoelEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            AccessoryCircularView(summary: entry.summary)
        case .accessoryRectangular:
            AccessoryRectangularView(summary: entry.summary)
        case .accessoryInline:
            AccessoryInlineView(summary: entry.summary)
        default:
            AccessoryInlineView(summary: entry.summary)
        }
    }
}
