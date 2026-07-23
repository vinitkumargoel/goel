import SwiftUI

/// The signature visual: one bar per live connection, each with its own byte range.
///
/// This is the picture no single-connection downloader can draw. Six bars at 100 / 78 / 64 /
/// 57 / 41 / 22 % with the finished one green is exactly what the engine is doing, not a
/// decoration — `Download.Segment.fraction` is the only input.
struct SegmentBars: View {

    let segments: [Download.Segment]
    let status: Download.Status

    /// A sweeping highlight is pure motion with no information in it, so it is the first thing
    /// to go when the user has asked the system for less movement.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        DetailCard(title: headline) {
            if segments.isEmpty {
                Text("This transfer runs on a single connection.")
                    .font(Theme.Typo.caption)
                    .foregroundStyle(Theme.Color.label3)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: DetailMetric.segmentRowSpacing) {
                    ForEach(segments) { segment in
                        SegmentRow(
                            segment: segment,
                            showsSheen: !reduceMotion && status.isActive && segment.isActive
                        )
                    }
                }
            }
        }
    }

    /// `PARALLEL CONNECTIONS — 6 ACTIVE`, and it is live.
    ///
    /// A segment that has finished its range is still one of the transfer's connections — the
    /// engine re-splits what is left and hands the connection more work — which is why the
    /// mockup reads "6 active" while one of the six bars is already green.
    var headline: String {
        let count = segments.count
        switch status {
        case .downloading, .probing, .verifying:
            let inFlight = segments.filter { $0.isActive || $0.isComplete }.count
            return "Parallel connections — \(inFlight) active"
        case .paused:
            return "Parallel connections — \(count) paused"
        case .waitingForWiFi, .queued:
            return "Parallel connections — \(count) waiting"
        case .completed:
            return "Parallel connections — \(count) complete"
        case .failed:
            return "Parallel connections — \(count) stopped"
        }
    }
}

// MARK: - One connection

/// `26 pt id · 7 pt bar · 42 pt percentage`, matching `.segrow`'s three-column grid.
private struct SegmentRow: View {

    let segment: Download.Segment
    let showsSheen: Bool

    var body: some View {
        HStack(spacing: DetailMetric.segmentColumnSpacing) {
            Text(String(format: "%02d", segment.id + 1))
                .font(DetailTypo.segmentID)
                .foregroundStyle(Theme.Color.label3)
                .frame(width: DetailMetric.segmentIDWidth, alignment: .leading)

            SegmentTrack(fraction: segment.fraction, style: fillStyle, showsSheen: showsSheen)

            Text(Fmt.percent(segment.fraction))
                .font(DetailTypo.segmentPercent)
                .foregroundStyle(Theme.Color.label2)
                .frame(width: DetailMetric.segmentPercentWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Connection \(segment.id + 1)")
        .accessibilityValue("\(Fmt.percentValue(segment.fraction)) percent")
    }

    /// Green when the range is fully fetched, the ember gradient while it is being fetched,
    /// flat `elev3` when the connection is not running. Never colour alone — the percentage
    /// beside every bar carries the same fact in text.
    private var fillStyle: AnyShapeStyle {
        if segment.isComplete { return AnyShapeStyle(Theme.Color.success) }
        if segment.isActive { return AnyShapeStyle(Theme.Color.emberGradient) }
        return AnyShapeStyle(Theme.Color.elev3)
    }
}

// MARK: - The bar

/// A 7 pt track with a rounded fill that glides to new values and, when live, carries the sheen.
private struct SegmentTrack: View {

    let fraction: Double
    let style: AnyShapeStyle
    let showsSheen: Bool

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Theme.Metric.segmentRadius, style: .continuous)
    }

    var body: some View {
        GeometryReader { proxy in
            let width = max(0, proxy.size.width * min(max(fraction, 0), 1))
            ZStack(alignment: .leading) {
                shape.fill(Theme.Color.idleTrack)

                shape
                    .fill(style)
                    .frame(width: width)
                    // The band is exactly as wide as the filled portion and is clipped to it,
                    // so the sheen only ever travels across bytes that have arrived.
                    .overlay(alignment: .leading) {
                        if showsSheen, width > 0 {
                            SheenBand(width: width)
                        }
                    }
                    .clipShape(shape)
            }
            .animation(.easeOut(duration: DetailMetric.barGrowth), value: fraction)
        }
        .frame(height: Theme.Metric.segmentBar)
    }
}

/// The sweep.
///
/// The band itself never changes: one `LinearGradient`, built once, rendered into one layer.
/// Only its horizontal offset moves, driven by wall-clock time from `TimelineView(.animation)`,
/// so every frame is a translation of an already-rasterised layer — no gradient is
/// re-interpolated, no layout is invalidated, and nothing outside this leaf is re-evaluated.
/// Animating a gradient's *stops* instead would re-rasterise the band every frame and visibly
/// stutter at 7 pt.
///
/// Reading the phase from `timeIntervalSinceReferenceDate` also means all six bars share one
/// clock, exactly like the CSS animation they came from: the sweeps stay in phase with each
/// other while landing at different absolute positions, because each fill is a different width.
private struct SheenBand: View {

    let width: CGFloat

    /// `linear-gradient(90deg, transparent, rgba(255,255,255,.42), transparent)`. A constant, so
    /// SwiftUI reuses the same rendered band on every frame.
    private static let gradient = LinearGradient(
        stops: [
            .init(color: .white.opacity(0), location: 0),
            .init(color: .white.opacity(DetailMetric.sheenOpacity), location: 0.5),
            .init(color: .white.opacity(0), location: 1),
        ],
        startPoint: .leading,
        endPoint: .trailing
    )

    var body: some View {
        TimelineView(.animation) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let phase = (elapsed / DetailMetric.sheenPeriod)
                .truncatingRemainder(dividingBy: 1)
            let travel = DetailMetric.sheenStart + DetailMetric.sheenTravel * phase

            Rectangle()
                .fill(Self.gradient)
                .frame(width: width)
                .offset(x: width * travel)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Previews

#Preview("Six segments — 100/78/64/57/41/22") {
    let ubuntu = PreviewTransferEngine.fixtures().first { $0.id == PreviewTransferEngine.ubuntuID }
    return VStack {
        SegmentBars(
            segments: ubuntu?.segments ?? [],
            status: ubuntu?.status ?? .downloading
        )
    }
    .padding(Theme.Metric.gutter)
    .frame(maxHeight: .infinity)
    .background(Theme.Color.ground)
    .preferredColorScheme(.dark)
}

#Preview("Paused") {
    let nas = PreviewTransferEngine.fixtures().first { $0.id == PreviewTransferEngine.nasBackupID }
    return VStack {
        SegmentBars(segments: nas?.segments ?? [], status: .paused)
    }
    .padding(Theme.Metric.gutter)
    .frame(maxHeight: .infinity)
    .background(Theme.Color.ground)
    .preferredColorScheme(.dark)
}

#Preview("Single connection") {
    VStack {
        SegmentBars(segments: [], status: .downloading)
    }
    .padding(Theme.Metric.gutter)
    .frame(maxHeight: .infinity)
    .background(Theme.Color.ground)
    .preferredColorScheme(.dark)
}
