import SwiftUI
import GoelCore

/// Which half of the combined read-out a graph draws.
enum SpeedDirection {
    case down, up

    var tint: Color { self == .down ? Theme.green : Theme.teal }
    var symbol: String { self == .down ? "arrow.down" : "arrow.up" }

    func value(_ sample: SpeedSample) -> Double { self == .down ? sample.down : sample.up }
}

/// The last minute of the status bar's ↓ or ↑ total, 60×18 pt beside the number. Clicking it
/// opens the five-minute graph of both directions.
struct GlobalSpeedSparkline: View {
    let direction: SpeedDirection
    @EnvironmentObject private var telemetry: TelemetryStore
    @State private var showsHistory = false

    static let inlineWindow = 60

    var body: some View {
        let history = telemetry.recentGlobalHistory(Self.inlineWindow)
        Button { showsHistory.toggle() } label: {
            SparklineView(values: history.map(direction.value), tint: direction.tint)
                .frame(width: 60, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.t("Speed over the last 5 minutes"))
        .a11yButton(direction == .down ? L10n.t("Download speed history")
                                       : L10n.t("Upload speed history"),
                    hint: L10n.t("Activate to show the last 5 minutes."))
        .accessibilityValue(L10n.t("peak %@ in the last minute",
                                   A11y.speed(history.map(direction.value).max() ?? 0)))
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
        let peak = max(SpeedHistoryWindow.peakDown(history), SpeedHistoryWindow.peakUp(history))
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(L10n.t("Speed · last 5 min"))
                .scaledFont(size: Theme.TextSize.title, weight: .semibold)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: Theme.Space.l) {
                legend(.down, history)
                legend(.up, history)
            }
            VStack(spacing: 3) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.chip)
                        .fill(Theme.fillRest)
                    SparklineView(values: history.map(\.down), tint: Theme.green, scalePeak: peak)
                        .padding(.vertical, 4)
                    SparklineView(values: history.map(\.up), tint: Theme.teal, scalePeak: peak)
                        .padding(.vertical, 4)
                }
                .frame(height: 120)
                HStack {
                    Text(Self.axisStart(span: span))
                    Spacer()
                    Text(L10n.t("now"))
                }
                .scaledFont(size: Theme.TextSize.caption)
                .foregroundStyle(.secondary)
                .a11yDecorative()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(L10n.t("Speed graph, last %d seconds", Int((span ?? 0).rounded())))
            .accessibilityValue(A11y.sentence(
                L10n.t("peak download %@", A11y.speed(SpeedHistoryWindow.peakDown(history))),
                L10n.t("peak upload %@", A11y.speed(SpeedHistoryWindow.peakUp(history)))))
        }
        .padding(Theme.Space.l)
        .frame(width: 360)
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
        return VStack(alignment: .leading, spacing: 2) {
            Label(current.speedString, systemImage: direction.symbol)
                .scaledFont(size: Theme.TextSize.body, weight: .semibold, monospacedDigit: true)
                .foregroundStyle(direction.tint)
            Text(L10n.t("peak %1$@ · avg %2$@", peak.speedString, average.speedString))
                .scaledFont(size: Theme.TextSize.caption, monospacedDigit: true)
                .foregroundStyle(.secondary)
        }
        .a11yGroup(label: direction == .down ? L10n.t("Download") : L10n.t("Upload"),
                   value: L10n.t("now %1$@, peak %2$@, average %3$@",
                                 A11y.speed(current), A11y.speed(peak), A11y.speed(average)))
    }
}
