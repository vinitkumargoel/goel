import SwiftUI

/// A vertical scroll view that fades its content out at an edge when more is hidden past it,
/// so a cut-off list reads as "scroll for more" instead of looking clipped. Neither edge fades
/// when everything fits.
///
/// ```swift
/// EdgeFadingScrollView { VStack { … } }
/// ```
struct EdgeFadingScrollView<Content: View>: View {
    var fadeLength: CGFloat = Studio.Space.xxl
    @ViewBuilder var content: Content

    @State private var metrics = ScrollMetrics()
    @State private var space = UUID()

    var body: some View {
        ScrollView {
            content
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ContentFrameKey.self, value: proxy.frame(in: .named(space)))
                })
        }
        .coordinateSpace(name: space)
        .background(GeometryReader { proxy in
            Color.clear.preference(key: ViewportHeightKey.self, value: proxy.size.height)
        })
        .onPreferenceChange(ContentFrameKey.self) { frame in
            metrics.offset = -frame.minY
            metrics.contentHeight = frame.height
        }
        .onPreferenceChange(ViewportHeightKey.self) { metrics.viewport = $0 }
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: metrics.hidesAbove ? fadeLength : 0)
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: metrics.hidesBelow ? fadeLength : 0)
            }
        }
    }
}

private struct ScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var contentHeight: CGFloat = 0
    var viewport: CGFloat = 0

    var hidesAbove: Bool { offset > 1 }
    var hidesBelow: Bool { contentHeight - offset - viewport > 1 }
}

private struct ContentFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

private struct ViewportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
