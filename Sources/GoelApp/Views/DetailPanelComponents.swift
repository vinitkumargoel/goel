import SwiftUI
import GoelCore

struct ProgressRing: View {
    let fraction: Double
    var tint: Color = Theme.accent
    var lineWidth: CGFloat = 11

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.10), lineWidth: lineWidth)
            Circle()
                // Floor of 0.004 so a just-started download still shows a cap dot.
                .trim(from: 0, to: max(0.004, min(1, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.opacity(0.45), radius: 4)
                .animation(.easeInOut(duration: 0.4), value: fraction)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.t("Progress"))
        .accessibilityValue(A11y.percent(fraction))
    }
}

@MainActor
final class ThroughputSampler: ObservableObject {
    @Published private(set) var samples: [Double]
    private let capacity: Int
    private var currentID: AnyHashable?

    init(capacity: Int = 44) {
        self.capacity = capacity
        self.samples = []
    }

    func record(_ value: Double, id: AnyHashable) {
        if id != currentID {
            currentID = id
            samples = []
        }
        samples.append(value)
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }

    /// Guard is a no-op once samples exist for this identity — else it clobbers a live session.
    func seed(_ values: [Double], id: AnyHashable) {
        guard id != currentID || samples.isEmpty else { return }
        currentID = id
        samples = Array(values.suffix(capacity))
    }
}

struct ThroughputGraph: View {
    let samples: [Double]
    var color: Color = Theme.green

    private var maxValue: Double { (samples.max() ?? 0) * 1.25 }

    var body: some View {
        ZStack {
            SparkPath(samples: samples, maxValue: maxValue, filled: true)
                .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0)],
                                     startPoint: .top, endPoint: .bottom))
            SparkPath(samples: samples, maxValue: maxValue, filled: false)
                .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.t("Recent throughput"))
        .accessibilityValue(spokenSummary)
    }

    private var spokenSummary: String {
        guard !samples.isEmpty else { return L10n.t("No samples yet") }
        let peak = samples.max() ?? 0
        let mean = samples.reduce(0, +) / Double(samples.count)
        return L10n.t("average %1$@, peak %2$@, over the last %3$@ seconds",
                      A11y.speed(mean), A11y.speed(peak), String(samples.count))
    }
}

private struct SparkPath: Shape {
    let samples: [Double]
    let maxValue: Double
    let filled: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard samples.count > 1 else { return path }
        let maxV = max(maxValue, 1)
        let stepX = rect.width / CGFloat(samples.count - 1)
        func point(_ i: Int) -> CGPoint {
            let norm = min(1, max(0, samples[i] / maxV))
            return CGPoint(x: rect.minX + CGFloat(i) * stepX,
                           y: rect.maxY - CGFloat(norm) * rect.height)
        }
        if filled {
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: point(0))
        } else {
            path.move(to: point(0))
        }
        for i in 1..<samples.count { path.addLine(to: point(i)) }
        if filled {
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
        }
        return path
    }
}

struct DetailSpeedStat: View {
    let symbol: String
    let speed: Double
    let color: Color
    var size: CGFloat = 12.5

    var body: some View {
        SpeedStat(symbol: symbol, speed: speed, color: color, size: size)
    }
}

struct DetailStatusPill: View {
    let task: DownloadTask

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(task.statusColor).frame(width: 6, height: 6)
            Text(task.status.displayName)
                .scaledFont(size: 11.5)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .a11yGroup(label: L10n.t("Status"), value: L10n.t(task.accessibilityStatusName))
    }
}

struct DetailActionButtons: View {
    let task: DownloadTask
    let vm: AppViewModel
    var fill: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            primary
            button(L10n.t("Folder"), "folder",
                   spoken: L10n.t("Show %@ in Finder", task.name)) { vm.revealInFinder(task) }
            button(L10n.t("Copy"), "doc.on.doc",
                   spoken: L10n.t("Copy source link for %@", task.name)) { vm.copyToPasteboard(task.sourceLocator) }
            if !fill { Spacer(minLength: 0) }
        }
    }

    @ViewBuilder private var primary: some View {
        if task.status.isActive {
            button(L10n.t("Pause"), "pause.fill", spoken: L10n.t("Pause %@", task.name), prominent: true) { vm.pause(task.id) }
        } else if task.status == .paused || task.status == .queued {
            button(L10n.t("Resume"), "play.fill", spoken: L10n.t("Resume %@", task.name), prominent: true) { vm.resume(task.id) }
        } else if case .failed = task.status {
            button(L10n.t("Retry"), "arrow.clockwise", spoken: L10n.t("Retry %@", task.name), prominent: true) { vm.retry(task.id) }
        }
    }

    private func button(_ title: String, _ symbol: String, spoken: String,
                        prominent: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .scaledFont(size: 11.5, weight: .medium)
                .frame(maxWidth: fill ? .infinity : nil)
                .padding(.horizontal, fill ? 4 : 10)
                .frame(height: 28)
                .background(prominent ? Theme.accent.opacity(0.16) : Color.primary.opacity(0.06),
                            in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.hairline))
                .foregroundStyle(prominent ? Theme.accent : Color.primary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .a11yButton(spoken)
    }
}

extension DownloadTask {
    var percentComplete: Int { Int((fractionCompleted * 100).rounded()) }

    var sizeProgressText: String {
        "\(bytesDownloaded.byteString) of \(totalBytes?.byteString ?? "—")"
    }

    var etaText: String? {
        guard let eta = estimatedTimeRemaining, eta > 0 else { return nil }
        return "~\(DownloadTask.etaString(eta))"
    }

    var swarmSummary: (label: String, value: String) {
        if kind == .torrent {
            let seeds = seedCount.map { " · " + L10n.t("%d seeds", $0) } ?? ""
            return (L10n.t("Peers"), "\(connectionCount)\(seeds)")
        }
        return (L10n.t("Connections"), "\(connectionCount)")
    }
}
