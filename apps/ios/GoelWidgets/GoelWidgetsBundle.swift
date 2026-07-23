import SwiftUI
import WidgetKit

@main
struct GoelWidgetsBundle: WidgetBundle {
    var body: some Widget {
        PlaceholderWidget()
    }
}

/// T01 placeholder so the extension has at least one valid widget and compiles.
/// Replaced by the real widgets in T13/T14.
struct PlaceholderWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "dev.goel.ios.placeholder", provider: PlaceholderProvider()) { entry in
            Text(entry.text)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Goel°")
        .description("Download activity.")
        .supportedFamilies([.systemSmall])
    }
}

struct PlaceholderEntry: TimelineEntry {
    let date: Date
    let text: String
}

struct PlaceholderProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlaceholderEntry {
        PlaceholderEntry(date: .now, text: "Goel°")
    }

    func getSnapshot(in context: Context, completion: @escaping (PlaceholderEntry) -> Void) {
        completion(PlaceholderEntry(date: .now, text: "Goel°"))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PlaceholderEntry>) -> Void) {
        completion(Timeline(entries: [PlaceholderEntry(date: .now, text: "Goel°")], policy: .never))
    }
}
