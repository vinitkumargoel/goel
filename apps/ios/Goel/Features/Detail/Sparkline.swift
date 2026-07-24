import SwiftUI

/// Throughput over the last sixty samples, drawn as one path.
///
/// One `Canvas`, two paths and a dot — not sixty stacked rectangles, because sixty views that
/// relayout on every engine tick is the difference between a sparkline and a stutter.
///
/// The vertical scale is the window's own maximum, so the shape always uses the full height and
/// a transfer that never exceeds 800 KB/s reads as legibly as one saturating a gigabit link.
/// The trade is that the line says nothing about absolute speed — which is what the ember rate
/// line above it is for.
struct Sparkline: View {

    /// Newest last, matching `Download.speedSamples`.
    let samples: [Double]

    var tint: Color = Theme.Color.ember

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, size in
            draw(in: &context, size: size)
        }
        .accessibilityElement()
        .accessibilityLabel("Throughput chart")
        .accessibilityValue(trendDescription)
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let points = Self.points(for: samples, in: size)
        guard let last = points.last else { return }

        if points.count > 1 {
            // Built one segment at a time on purpose: `addLines` begins its own subpath with a
            // `move`, which orphans the floor point and leaves `closeSubpath` drawing a diagonal
            // from the right-hand floor straight back to the first sample — a wedge under the
            // curve instead of a fill.
            var area = Path()
            area.move(to: CGPoint(x: points[0].x, y: size.height))
            for point in points { area.addLine(to: point) }
            area.addLine(to: CGPoint(x: last.x, y: size.height))
            area.closeSubpath()

            // stop-opacity .42 at the line, 0 at the floor.
            context.fill(
                area,
                with: .linearGradient(
                    Gradient(colors: [
                        tint.opacity(DetailMetric.sparklineAreaOpacity),
                        tint.opacity(0),
                    ]),
                    startPoint: .zero,
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
        }

        var line = Path()
        line.addLines(points)
        context.stroke(
            line,
            with: .color(tint),
            style: StrokeStyle(
                lineWidth: DetailMetric.sparklineLineWidth,
                lineCap: .round,
                lineJoin: .round
            )
        )

        // The endpoint is what makes it read as live rather than as a static illustration.
        let radius = DetailMetric.sparklineEndpointRadius
        context.fill(
            Path(ellipseIn: CGRect(
                x: last.x - radius,
                y: last.y - radius,
                width: radius * 2,
                height: radius * 2
            )),
            with: .color(tint)
        )
    }

    /// Maps samples onto the canvas, normalised to the window maximum.
    ///
    /// Three degenerate inputs are handled here rather than at the call site: an empty window
    /// draws nothing, a single sample becomes a flat line so the endpoint still has somewhere to
    /// sit, and an all-zero window pins to the floor instead of dividing by a zero maximum.
    static func points(for samples: [Double], in size: CGSize) -> [CGPoint] {
        let clean = samples.filter(\.isFinite).map { max(0, $0) }
        guard !clean.isEmpty, size.width > 0, size.height > 0 else { return [] }

        // Room for the endpoint dot at every edge, so it is never half-clipped.
        let inset = DetailMetric.sparklineEndpointRadius
        let left = inset
        let right = max(left, size.width - inset)
        let top = inset
        let bottom = max(top, size.height - inset)
        let span = bottom - top

        // An all-zero window — a paused transfer — pins to the floor rather than dividing by
        // a zero peak.
        let peak = clean.max() ?? 0
        func y(_ value: Double) -> CGFloat {
            guard peak > 0 else { return bottom }
            let normalised = min(max(value / peak, 0), 1)
            return bottom - CGFloat(normalised) * span
        }

        guard clean.count > 1 else {
            let level = y(clean[0])
            return [CGPoint(x: left, y: level), CGPoint(x: right, y: level)]
        }

        let step = (right - left) / CGFloat(clean.count - 1)
        return clean.enumerated().map { index, value in
            CGPoint(x: left + CGFloat(index) * step, y: y(value))
        }
    }

    // MARK: Accessibility

    /// The shape conveys nothing to a screen reader, so the trend is stated in words.
    var trendDescription: String {
        let clean = samples.filter(\.isFinite).map { max(0, $0) }
        guard let latest = clean.last, let peak = clean.max() else {
            return "No throughput recorded yet"
        }
        guard clean.count >= 4 else {
            return "Currently \(Fmt.speed(latest))"
        }

        let split = clean.count / 2
        let earlier = mean(of: Array(clean.prefix(split)))
        let recent = mean(of: Array(clean.suffix(clean.count - split)))
        let trend: String
        if earlier <= 0 {
            trend = recent > 0 ? "rising from a standstill" : "flat at zero"
        } else if recent > earlier * 1.1 {
            trend = "rising"
        } else if recent < earlier * 0.9 {
            trend = "falling"
        } else {
            trend = "steady"
        }

        return "\(clean.count) samples, \(trend), peaking at \(Fmt.speed(peak)), now \(Fmt.speed(latest))"
    }

    private func mean(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sum = values.reduce(0, +)
        guard sum.isFinite else { return 0 }
        return sum / Double(values.count)
    }
}

// MARK: - Previews

@MainActor
private func sparklinePreviewCard(_ title: String, _ samples: [Double]) -> some View {
    DetailCard(title: title) {
        Sparkline(samples: samples)
            .frame(height: DetailMetric.sparklineHeight)
    }
    .padding(Theme.Metric.gutter)
    .background(Theme.Color.ground)
    .preferredColorScheme(.dark)
}

#Preview("Throughput — last 60 s") {
    let ubuntu = PreviewTransferEngine.fixtures().first { $0.id == PreviewTransferEngine.ubuntuID }
    return sparklinePreviewCard("Throughput — last 60 s", ubuntu?.speedSamples ?? [])
}

#Preview("Degenerate windows") {
    VStack(spacing: DetailMetric.cardSpacing) {
        sparklinePreviewCard("Empty", [])
        sparklinePreviewCard("All zeros", Array(repeating: 0, count: 60))
        sparklinePreviewCard("One sample", [12_400_000])
    }
    .frame(maxHeight: .infinity)
    .background(Theme.Color.ground)
    .preferredColorScheme(.dark)
}
