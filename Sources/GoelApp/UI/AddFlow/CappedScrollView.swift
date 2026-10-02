import SwiftUI
import AppKit

/// A scroll view that is exactly as tall as its content until it reaches `maxHeight`, then
/// scrolls. A plain `ScrollView` inside a sheet has no ideal height of its own, so without the
/// measurement the sheet either collapses it or grows past the screen.
struct CappedScrollView<Content: View>: View {
    var maxHeight: CGFloat
    @ViewBuilder var content: Content

    @State private var contentHeight: CGFloat = 0

    /// The tallest a sheet body should get on this screen: leaves room for the sheet's own
    /// header and footer and the menu bar on a 13-inch display.
    static func screenCap(reserving chrome: CGFloat, upTo limit: CGFloat) -> CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 800
        return max(240, min(limit, visible - chrome))
    }

    var body: some View {
        ScrollView {
            content
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                })
        }
        .frame(height: min(max(contentHeight, 1), maxHeight))
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
