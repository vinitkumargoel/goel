import SwiftUI
import GoelCore

struct SparklineView: View {
    let values: [Double]
    var tint: Color = Theme.accent

    var body: some View {
        GeometryReader { geo in
            let peak = max(values.max() ?? 0, 1)
            let points = Self.points(values: values, peak: peak, in: geo.size)
            ZStack {
                if points.count > 1 {
                    areaPath(points, size: geo.size)
                        .fill(tint.opacity(0.15))
                    linePath(points)
                        .stroke(tint, style: StrokeStyle(lineWidth: 1.5,
                                                         lineCap: .round, lineJoin: .round))
                }
            }
        }
        .a11yDecorative()
    }

    private static func points(values: [Double], peak: Double, in size: CGSize) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let stepX = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { i, v in
            CGPoint(x: CGFloat(i) * stepX,
                    y: size.height - CGFloat(v / peak) * size.height)
        }
    }

    private func linePath(_ points: [CGPoint]) -> Path {
        Path { p in
            p.move(to: points[0])
            for point in points.dropFirst() { p.addLine(to: point) }
        }
    }

    private func areaPath(_ points: [CGPoint], size: CGSize) -> Path {
        Path { p in
            p.move(to: CGPoint(x: points[0].x, y: size.height))
            for point in points { p.addLine(to: point) }
            p.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
            p.closeSubpath()
        }
    }
}

struct TaskSpeedGraph: View {
    let taskID: DownloadTask.ID
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        let history = vm.taskSpeedHistory[taskID] ?? []
        if history.count > 2 {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(text: "Speed · last \(history.count)s")
                ZStack {
                    SparklineView(values: history.map(\.down), tint: Theme.accent)
                    SparklineView(values: history.map(\.up), tint: Theme.teal)
                }
                .frame(height: 44)
            }
            // `.updatesFrequently` below stops VoiceOver caching a stale value.
            .a11yGroup(
                label: "Speed graph, last \(history.count) seconds",
                value: A11y.sentence(
                    "Download \(A11y.speed(history.last?.down ?? 0))",
                    "upload \(A11y.speed(history.last?.up ?? 0))",
                    "peak download \(A11y.speed(history.map(\.down).max() ?? 0))"))
            .accessibilityAddTraits(.updatesFrequently)
        }
    }
}

struct StatsView: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var stats: TransferStats?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Statistics").scaledFont(size: 16, weight: .bold)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("Done") { vm.isStatsPresented = false }
                    .keyboardShortcut(.defaultAction)
            }

            if let stats {
                HStack(spacing: 12) {
                    statCard("Downloaded", stats.totalDownloadedBytes.byteString, Theme.accent,
                             spoken: A11y.bytes(stats.totalDownloadedBytes))
                    statCard("Uploaded", stats.totalUploadedBytes.byteString, Theme.teal,
                             spoken: A11y.bytes(stats.totalUploadedBytes))
                    statCard("Completed", "\(stats.completedCount)", Theme.green,
                             spoken: "\(stats.completedCount) downloads")
                }

                let today = stats.today()
                HStack(spacing: 12) {
                    statCard("Today ↓", today.down.byteString, Theme.accent,
                             spokenLabel: "Downloaded today", spoken: A11y.bytes(today.down))
                    statCard("Today ↑", today.up.byteString, Theme.teal,
                             spokenLabel: "Uploaded today", spoken: A11y.bytes(today.up))
                }

                SectionLabel(text: "Last 14 days")
                dailyBars(stats.lastDays(14))
            } else {
                ProgressView().frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityLabel("Loading statistics")
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(width: 460, height: 380)
        .task { stats = await vm.fetchStats() }
    }

    private func statCard(_ label: String, _ value: String, _ tint: Color,
                          spokenLabel: String? = nil, spoken: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).scaledFont(size: 10.5, weight: .semibold)
                .foregroundStyle(.secondary)
            Text(value).scaledFont(size: 15, weight: .bold, monospacedDigit: true)
                .foregroundStyle(tint)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
        .a11yGroup(label: spokenLabel ?? label, value: spoken ?? value)
    }

    private func dailyBars(_ days: [(day: String, totals: TransferStats.DayTotals)]) -> some View {
        let peak = max(days.map { $0.totals.down + $0.totals.up }.max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 5) {
            ForEach(days, id: \.day) { entry in
                let total = entry.totals.down + entry.totals.up
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(total > 0 ? Theme.accent : Color.primary.opacity(0.08))
                        .frame(height: max(3, CGFloat(Double(total) / Double(peak)) * 80))
                        .help("\(entry.day): ↓ \(entry.totals.down.byteString) · ↑ \(entry.totals.up.byteString)")
                    Text(String(entry.day.suffix(2)))
                        .scaledFont(size: 8.5)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .a11yGroup(
                    label: entry.day,
                    value: A11y.sentence("downloaded \(A11y.bytes(entry.totals.down))",
                                         "uploaded \(A11y.bytes(entry.totals.up))"))
            }
        }
        .frame(height: 100, alignment: .bottom)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Daily transfer totals, last 14 days")
    }
}
