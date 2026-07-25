import ActivityKit
import SwiftUI
import WidgetKit

/// The hero surface — PRD §6.5. All four presentations, each designed rather than defaulted.
///
/// | Presentation | What it shows |
/// |---|---|
/// | Lock Screen / banner | glyph, filename, `3.61 of 5.73 GB · 48.2 MB/s`, `63%`, bar, Pause + Cancel |
/// | Compact | leading: kind glyph · trailing: progress ring |
/// | Minimal | the ring alone |
/// | Expanded | glyph / filename + speed + ETA / percent, then bar and both buttons |
///
/// **The fifth state is the one that matters.** `context.isStale` flips every presentation into
/// the degraded layout drawn in `visual.html` frame 6: no percentage, no ETA, a byte count and
/// `updated 2 min ago`, and a desaturated bar. It exists because during a background
/// `URLSession` the app is not running, ActivityKit is not being fed, and a precise-looking
/// number would be a confident lie. `ActivityController` publishes with a 90 s `staleDate` so
/// the system flips us here automatically.
///
/// The layouts themselves live in `Shared/WidgetViews.swift`, because the Lock Screen cannot be
/// shown from `simctl` and the in-app Widget Gallery has to render the very same views to be
/// worth anything as verification.
struct DownloadLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            // Lock Screen / banner.
            LiveActivityLockScreenView(
                state: context.state,
                downloadID: context.attributes.downloadID,
                kindToken: context.attributes.kindToken,
                isStale: context.isStale
            )
            .activityBackgroundTint(WidgetPalette.cardFill)
            .activitySystemActionForegroundColor(SharedTheme.ember)
            .widgetURL(GoelWidgetLink.download(id: context.attributes.downloadID))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    IslandExpanded.leading(
                        kindToken: context.attributes.kindToken,
                        isStale: context.isStale
                    )
                }
                DynamicIslandExpandedRegion(.center) {
                    IslandExpanded.center(state: context.state, isStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    IslandExpanded.trailing(state: context.state, isStale: context.isStale)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    IslandExpanded.bottom(
                        state: context.state,
                        downloadID: context.attributes.downloadID,
                        isStale: context.isStale
                    )
                }
            } compactLeading: {
                Image(systemName: WidgetGlyph.arrow)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(context.isStale ? SharedTheme.label3 : SharedTheme.ember)
                    .accessibilityLabel("Downloading")
            } compactTrailing: {
                WidgetProgressRing(
                    fraction: context.state.fraction,
                    diameter: 21,
                    lineWidth: 3,
                    tint: context.isStale ? WidgetPalette.staleFill : SharedTheme.ember
                )
            } minimal: {
                WidgetProgressRing(
                    fraction: context.state.fraction,
                    diameter: 21,
                    lineWidth: 3,
                    tint: context.isStale ? WidgetPalette.staleFill : SharedTheme.ember
                )
            }
            .keylineTint(SharedTheme.ember)
            .widgetURL(GoelWidgetLink.download(id: context.attributes.downloadID))
        }
    }
}
