import SwiftUI
import GoelCore

/// Which half of the combined read-out a graph draws.
enum SpeedDirection {
    case down, up

    var tint: Color { self == .down ? Studio.Palette.accent : Studio.Palette.upload }
    var symbol: String { self == .down ? "arrow.down" : "arrow.up" }

    func value(_ sample: SpeedSample) -> Double { self == .down ? sample.down : sample.up }
}

/// The slice of a 1 Hz speed ring a graph draws, and the numbers printed beside it.
enum SpeedHistoryWindow {
    static func tail(_ samples: [SpeedSample], count: Int) -> [SpeedSample] {
        guard count > 0 else { return [] }
        return samples.count > count ? Array(samples.suffix(count)) : samples
    }

    static func peakDown(_ samples: [SpeedSample]) -> Double { samples.map(\.down).max() ?? 0 }
    static func peakUp(_ samples: [SpeedSample]) -> Double { samples.map(\.up).max() ?? 0 }

    static func average(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }
}

/// A small area sparkline in one tint (`.spark`). Pass one shared `scalePeak` when two series
/// overlay each other, or each would be scaled to itself and a trickle would look as tall as the
/// main stream.
struct SparklineView: View {
    let values: [Double]
    var tint: Color = Studio.Palette.accent
    var scalePeak: Double? = nil

    var body: some View {
        Canvas { context, size in
            let peak = max(scalePeak ?? values.max() ?? 0, 1)
            guard values.count > 1 else { return }
            let step = size.width / CGFloat(values.count - 1)
            let points = values.enumerated().map { index, value in
                CGPoint(x: CGFloat(index) * step,
                        y: size.height - CGFloat(max(0, value) / peak) * (size.height - 1))
            }
            var area = Path()
            area.move(to: CGPoint(x: points[0].x, y: size.height))
            points.forEach { area.addLine(to: $0) }
            area.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
            area.closeSubpath()
            context.fill(area, with: .color(tint.opacity(0.16)))
            var line = Path()
            line.move(to: points[0])
            points.dropFirst().forEach { line.addLine(to: $0) }
            context.stroke(line, with: .color(tint),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

/// One download's recent speed for the detail panel: ↓ as the accent area, ↑ as the dashed line.
struct TaskSpeedGraph: View {
    let taskID: DownloadTask.ID
    /// Seconds of history drawn: one ring point per second.
    var window: Int = 60
    var height: CGFloat = 44
    @EnvironmentObject private var telemetry: TelemetryStore

    var body: some View {
        let history = SpeedHistoryWindow.tail(telemetry.taskHistory(taskID), count: window)
        if history.count > 2 {
            let peak = SpeedHistoryWindow.peakDown(history)
            let peakUp = SpeedHistoryWindow.peakUp(history)
            // A seeding torrent moves nothing down: its upload becomes the main line.
            let uploadOnly = peak == 0 && peakUp > 0
            VStack(alignment: .leading, spacing: Studio.Space.xs) {
                StudioSectionHeader(L10n.t("Speed · last %ds", window),
                                    detail: L10n.t("peak %@", (uploadOnly ? peakUp : peak).speedString))
                StudioSparkline(values: uploadOnly ? history.map(\.up) : history.map(\.down),
                                secondary: !uploadOnly && peakUp > 0 ? history.map(\.up) : nil,
                                gridLines: 1, showsEndDot: true,
                                color: uploadOnly ? Studio.Palette.upload : Studio.Palette.accent,
                                fillColor: uploadOnly ? Studio.Palette.uploadSoft : Studio.Palette.accentSoft)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .accessibilityHidden(true)
            }
            // `.updatesFrequently` below stops VoiceOver caching a stale value.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.t("Speed graph, last %d seconds", history.count))
            .accessibilityValue(A11y.sentence(
                L10n.t("Download %@", A11y.speed(history.last?.down ?? 0)),
                L10n.t("upload %@", A11y.speed(history.last?.up ?? 0)),
                L10n.t("peak download %@", A11y.speed(peak))))
            .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

/// The last minute of the status bar's ↓ or ↑ total, 60×18 pt beside the number. Clicking it
/// opens the five-minute graph of both directions.
struct GlobalSpeedSparkline: View {
    let direction: SpeedDirection
    @EnvironmentObject private var telemetry: TelemetryStore
    @State private var showsHistory = false
    @State private var hovered = false

    static let inlineWindow = 60

    var body: some View {
        let history = telemetry.recentGlobalHistory(Self.inlineWindow)
        let values = history.map(direction.value)
        Button { showsHistory.toggle() } label: {
            SparklineView(values: values, tint: direction.tint)
                .frame(width: 60, height: 18)
                .padding(.horizontal, 3)
                .padding(.vertical, Studio.Space.hair)
                .background(hovered ? Studio.Palette.segment : .clear,
                            in: RoundedRectangle(cornerRadius: Studio.Radius.badge, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(L10n.t("Speed over the last 5 minutes"))
        .a11yButton(direction == .down ? L10n.t("Download speed history")
                                       : L10n.t("Upload speed history"),
                    hint: L10n.t("Activate to show the last 5 minutes."))
        .accessibilityValue(L10n.t("peak %@ in the last minute", A11y.speed(values.max() ?? 0)))
        .popover(isPresented: $showsHistory, arrowEdge: .top) {
            GlobalSpeedHistoryPopover(telemetry: telemetry)
        }
    }
}

/// Five minutes of the combined ↓ and ↑ speed on one shared scale, with the current, peak and
/// average of each.
struct GlobalSpeedHistoryPopover: View {
    @ObservedObject var telemetry: TelemetryStore

    var body: some View {
        let history = telemetry.globalHistory
        let span = telemetry.globalHistorySpan()
        let downs = history.map(\.down)
        VStack(alignment: .leading, spacing: Studio.Space.sm) {
            Text(L10n.t("Speed · last 5 min"))
                .studioFont(.title3)
                .foregroundStyle(Studio.Palette.ink)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: Studio.Space.xxs) {
                StudioSparkline(values: downs, secondary: history.map(\.up), gridLines: 2, showsEndDot: true)
                    .frame(height: 110)
                    .accessibilityHidden(true)
                HStack {
                    Text(Self.axisStart(span: span))
                    Spacer()
                    Text(L10n.t("now"))
                }
                .studioFont(.monoSmall)
                .foregroundStyle(Studio.Palette.ink3)
                .accessibilityHidden(true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.t("Speed graph, last %d seconds", Int((span ?? 0).rounded())))
            .accessibilityValue(A11y.sentence(
                L10n.t("peak download %@", A11y.speed(SpeedHistoryWindow.peakDown(history))),
                L10n.t("peak upload %@", A11y.speed(SpeedHistoryWindow.peakUp(history)))))
            VStack(spacing: Studio.Space.xs) {
                legend(.down, history)
                legend(.up, history)
            }
        }
        .padding(.horizontal, Studio.Space.section)
        .padding(.top, Studio.Space.l)
        .padding(.bottom, Studio.Space.l)
        .frame(width: 360)
        .background(Studio.Palette.cardRaised)
    }

    /// From the oldest point's own time: idle stretches are not sampled, so a point count would
    /// understate how far back the graph reaches.
    static func axisStart(span: TimeInterval?) -> String {
        guard let span else { return "" }
        return L10n.t("%@ ago", DisplayFormat.duration(span.rounded(), locale: DisplayFormat.appLocale))
    }

    private func legend(_ direction: SpeedDirection, _ history: [SpeedSample]) -> some View {
        let values = history.map(direction.value)
        let current = values.last ?? 0
        let peak = values.max() ?? 0
        let average = SpeedHistoryWindow.average(values)
        return HStack(spacing: Studio.Space.s) {
            Image(systemName: direction.symbol)
                .studioFont(.ui, size: 11, weight: 700)
                .foregroundStyle(direction.tint)
            Text(current.speedString)
                .studioFont(.mono.weight(600))
                .foregroundStyle(direction.tint)
                .fixedSize()
            Spacer(minLength: Studio.Space.xs)
            Text(L10n.t("peak %1$@ · avg %2$@", peak.speedString, average.speedString))
                .studioFont(.monoSmall)
                .foregroundStyle(Studio.Palette.ink3)
                .minimumScaleFactor(0.8)
        }
        .lineLimit(1)
        .padding(.horizontal, Studio.Space.sm)
        .padding(.vertical, Studio.Space.s)
        .background(Studio.Palette.well, in: RoundedRectangle(cornerRadius: Studio.Radius.small, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(direction == .down ? L10n.t("Download") : L10n.t("Upload"))
        .accessibilityValue(L10n.t("now %1$@, peak %2$@, average %3$@",
                                   A11y.speed(current), A11y.speed(peak), A11y.speed(average)))
    }
}
