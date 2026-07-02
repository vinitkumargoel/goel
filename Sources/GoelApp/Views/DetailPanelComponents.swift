import SwiftUI
import GoelCore

// Shared building blocks for the redesigned detail panels — the bottom-dock
// "Command Center" (three zones) and the right-dock "Hero Ring". Kept in one
// place so both docks stay visually identical: same ring, same speed/status
// chrome, same action bar.

// MARK: - Progress ring (right-dock hero)

/// A circular progress gauge: a faint full track under a tinted arc that fills
/// clockwise from 12 o'clock. The caller overlays the centre content (percent /
/// label). Animates as `fraction` changes so it eases rather than jumps.
struct ProgressRing: View {
    let fraction: Double
    var tint: Color = Theme.accent
    var lineWidth: CGFloat = 11

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.10), lineWidth: lineWidth)
            Circle()
                // A hair above zero so a just-started download still shows a cap
                // dot rather than nothing.
                .trim(from: 0, to: max(0.004, min(1, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.opacity(0.45), radius: 4)
                .animation(.easeInOut(duration: 0.4), value: fraction)
        }
    }
}

// MARK: - Throughput sparkline (bottom-dock telemetry)

/// A rolling buffer of recent download-speed samples, driven by the panel's
/// once-a-second timer. Resets itself whenever the observed task changes so the
/// graph never blends two downloads' histories.
@MainActor
final class ThroughputSampler: ObservableObject {
    @Published private(set) var samples: [Double]
    private let capacity: Int
    private var currentID: AnyHashable?

    init(capacity: Int = 44) {
        self.capacity = capacity
        self.samples = Array(repeating: 0, count: capacity)
    }

    /// Append the latest speed. If the identity changed since the last sample,
    /// the window is cleared first so a newly selected download starts fresh.
    func record(_ value: Double, id: AnyHashable) {
        if id != currentID {
            currentID = id
            samples = Array(repeating: 0, count: capacity)
        }
        samples.append(value)
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }
}

/// Plots `samples` as a filled area under a stroked line, normalised to the
/// window's own peak (with a little headroom) so the shape uses the full height
/// regardless of absolute speed.
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
    }
}

/// The polyline through the samples. With `filled` it closes down to the
/// baseline on both ends to make an area; otherwise it's just the top line.
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

// MARK: - Shared chrome

/// A ↓ / ↑ speed readout: coloured while transferring, dimmed to "—" at rest.
struct DetailSpeedStat: View {
    let symbol: String
    let speed: Double
    let color: Color
    var size: CGFloat = 12.5

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: size - 1.5, weight: .bold))
            Text(speed > 0 ? speed.speedString : "—")
                .font(.system(size: size, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(speed > 0 ? color : Color.secondary)
    }
}

/// The coloured status dot + label ("Downloading", "Paused · 32%", …).
struct DetailStatusPill: View {
    let task: DownloadTask

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(task.statusColor).frame(width: 6, height: 6)
            Text(task.status.displayName)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// The contextual primary action (Pause / Resume / Retry, depending on state)
/// followed by Folder and Copy. Shared by both docks so the buttons match. Holds
/// `vm` as a plain reference rather than reading the environment, mirroring the
/// list row's `StateButton`.
struct DetailActionButtons: View {
    let task: DownloadTask
    let vm: AppViewModel
    /// When true the buttons stretch to share the available width (right dock's
    /// narrow footer); otherwise they size to their labels (wide bottom dock).
    var fill: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            primary
            button("Folder", "folder") { vm.revealInFinder(task) }
            button("Copy", "doc.on.doc") { vm.copyToPasteboard(task.sourceLocator) }
            if !fill { Spacer(minLength: 0) }
        }
    }

    @ViewBuilder private var primary: some View {
        if task.status.isActive {
            button("Pause", "pause.fill", prominent: true) { vm.pause(task.id) }
        } else if task.status == .paused || task.status == .queued {
            button("Resume", "play.fill", prominent: true) { vm.resume(task.id) }
        } else if case .failed = task.status {
            button("Retry", "arrow.clockwise", prominent: true) { vm.retry(task.id) }
        }
    }

    private func button(_ title: String, _ symbol: String,
                        prominent: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11.5, weight: .medium))
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
    }
}

// MARK: - Derived display helpers

extension DownloadTask {
    /// The percent-complete integer (0…100) used by the big headline numbers.
    var percentComplete: Int { Int((fractionCompleted * 100).rounded()) }

    /// "244.50 MB of 770.31 MB" — downloaded over total (total may be unknown).
    var sizeProgressText: String {
        "\(bytesDownloaded.byteString) of \(totalBytes?.byteString ?? "—")"
    }

    /// A short "~6m" style estimate, or nil when not downloading / unknown.
    var etaText: String? {
        guard let eta = estimatedTimeRemaining, eta > 0 else { return nil }
        return "~\(DownloadTask.etaString(eta))"
    }

    /// The swarm/connection summary shown in the telemetry column: peers + seeds
    /// for torrents, open connections for HTTP.
    var swarmSummary: (label: String, value: String) {
        if kind == .torrent {
            let seeds = seedCount.map { " · \($0) seeds" } ?? ""
            return ("Peers", "\(connectionCount)\(seeds)")
        }
        return ("Connections", "\(connectionCount)")
    }
}
