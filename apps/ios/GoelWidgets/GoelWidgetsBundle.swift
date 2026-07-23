import SwiftUI
import WidgetKit

/// Every surface the extension owns: the Live Activity (T13) and the WidgetKit widgets (T14).
///
/// The Live Activity and the widgets share this process but not their update models — the
/// activity is app-driven and best-effort, the widgets are timeline-driven and budgeted. Keeping
/// them in one bundle is only a packaging decision; see `LiveActivityWidget.swift` and
/// `HomeWidgets.swift` for the two very different sets of rules.
@main
struct GoelWidgetsBundle: WidgetBundle {
    var body: some Widget {
        DownloadLiveActivityWidget()
        GoelSummaryWidget()
        GoelFastestWidget()
        GoelQueueWidget()
        GoelAccessoryWidget()
        GoelActiveCountWidget()
    }
}
