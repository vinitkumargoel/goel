import SwiftUI
import GoelCore

// MARK: - Sparkline

/// A dependency-free area sparkline over a series of values, auto-scaled to
/// the series' peak. Used for the per-task and global speed histories.
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

/// The detail panel's per-task speed graph (download + upload overlaid).
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
        }
    }
}

// MARK: - Statistics sheet

/// Lifetime + per-day transfer statistics, loaded from the persisted
/// ``TransferStats`` when the sheet opens.
struct StatsView: View {
    @EnvironmentObject private var vm: AppViewModel
    @State private var stats: TransferStats?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Statistics").font(.system(size: 16, weight: .bold))
                Spacer()
                Button("Done") { vm.isStatsPresented = false }
                    .keyboardShortcut(.defaultAction)
            }

            if let stats {
                HStack(spacing: 12) {
                    statCard("Downloaded", stats.totalDownloadedBytes.byteString, Theme.accent)
                    statCard("Uploaded", stats.totalUploadedBytes.byteString, Theme.teal)
                    statCard("Completed", "\(stats.completedCount)", Theme.green)
                }

                let today = stats.today()
                HStack(spacing: 12) {
                    statCard("Today ↓", today.down.byteString, Theme.accent)
                    statCard("Today ↑", today.up.byteString, Theme.teal)
                }

                SectionLabel(text: "Last 14 days")
                dailyBars(stats.lastDays(14))
            } else {
                ProgressView().frame(maxWidth: .infinity, alignment: .center)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(width: 460, height: 380)
        .task { stats = await vm.fetchStats() }
    }

    private func statCard(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .bold)).monospacedDigit()
                .foregroundStyle(tint)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
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
                        .font(.system(size: 8.5))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 100, alignment: .bottom)
    }
}
