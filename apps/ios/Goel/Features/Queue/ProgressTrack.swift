import SwiftUI

/// The thin capsule bar under a row's filename — `visual.html`'s `.track`.
///
/// ```css
/// .track   { height: 4px; border-radius: 2px; background: rgba(120,120,128,.32); }
/// .track i { height: 100%; border-radius: 2px; background: var(--ios-ember); }
/// ```
///
/// It is deliberately dumb: a clamped fraction and a fill style, nothing else. T08 reuses it at
/// ``Theme/Metric/segmentBar`` (7 pt) for the per-segment bars, which is why `height` and `fill`
/// are parameters rather than baked in.
///
/// The glide is owned here rather than at the call site. Progress arrives at ~10 Hz and a bar
/// that jumps on every tick reads as noise; a 0.3 s linear ramp makes it read as motion. Pass
/// `isAnimated: false` where the value is static (previews, screenshots, a finished segment).
public struct ProgressTrack: View {

    /// Values off `visual.html` that ``Theme/Metric`` does not carry yet. Named here so no
    /// literal appears in a view body — fold them into `Theme.swift` when that file is next open.
    private enum Local {
        /// `.animation(.linear(duration: 0.3), value: fraction)` — one tick's worth of glide.
        static let glide: Double = 0.3
    }

    /// Already clamped to `0...1` and guaranteed finite by ``init(fraction:height:fill:isAnimated:)``.
    private let fraction: Double
    private let height: CGFloat
    private let fill: AnyShapeStyle
    private let isAnimated: Bool

    /// - Parameters:
    ///   - fraction: completion, clamped to `0...1`. `NaN` and `inf` become `0` rather than
    ///     propagating into a frame width, where they crash layout.
    ///   - height: 4 pt by default; T08 reuses this at 7 pt for segment bars.
    ///   - fill: any shape style — the ember gradient by default, a flat cyan for SFTP.
    ///   - isAnimated: whether a change in `fraction` glides.
    public init(
        fraction: Double,
        height: CGFloat = Theme.Metric.progressBar,
        fill: AnyShapeStyle = AnyShapeStyle(Theme.Color.emberGradient),
        isAnimated: Bool = true
    ) {
        self.fraction = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        self.height = height
        self.fill = fill
        self.isAnimated = isAnimated
    }

    public var body: some View {
        // A `Capsule` rather than a rounded rect: the CSS radius is exactly half the height at
        // both 4 pt and 7 pt, which is the definition of a capsule, so one shape covers T07 and
        // T08 without a second radius token.
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Theme.Color.idleTrack)
                Capsule(style: .continuous)
                    .fill(fill)
                    .frame(width: max(0, proxy.size.width * fraction))
            }
        }
        .frame(height: height)
        // Shapes are not accessibility elements, so this contributes nothing to VoiceOver on its
        // own. The row publishes the same number as an `.accessibilityValue`, which is what keeps
        // progress from being conveyed by colour alone.
        .animation(isAnimated ? .linear(duration: Local.glide) : nil, value: fraction)
    }
}

// MARK: - Previews

#Preview("Track · states") {
    VStack(alignment: .leading, spacing: 18) {
        ProgressTrack(fraction: 0.63, isAnimated: false)
        ProgressTrack(
            fraction: 0.31,
            fill: AnyShapeStyle(Theme.Color.instrument),
            isAnimated: false
        )
        ProgressTrack(
            fraction: 0.08,
            fill: AnyShapeStyle(Theme.Color.label3),
            isAnimated: false
        )
        // T08 reuses the same view at segment thickness.
        ProgressTrack(
            fraction: 0.78,
            height: Theme.Metric.segmentBar,
            isAnimated: false
        )
    }
    .padding(Theme.Metric.gutter)
    .background(Theme.Color.ground)
    .preferredColorScheme(.dark)
}
