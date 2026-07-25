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
        // Two stroked circles carry no meaning to assistive technology. Callers
        // that overlay their own richer readout (the hero) replace this by
        // collapsing the whole ZStack; this keeps the bare ring meaningful
        // wherever it is used alone.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Progress")
        .accessibilityValue(A11y.percent(fraction))
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
        // Start empty rather than a synthetic all-zero window: the graph draws
        // nothing until real samples arrive, so "no data yet" never reads as a
        // measured 0 B/s that ramps up over the buffer's length.
        self.samples = []
    }

    /// Append the latest speed. If the identity changed since the last sample,
    /// the window is cleared first so a newly selected download starts fresh.
    func record(_ value: Double, id: AnyHashable) {
        if id != currentID {
            currentID = id
            samples = []
        }
        samples.append(value)
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }

    /// Prime the window with a download's restored history so its chart resumes
    /// instead of starting blank. No-op once samples for this identity already
    /// exist (a live session shouldn't be clobbered by a re-seed).
    func seed(_ values: [Double], id: AnyHashable) {
        guard id != currentID || samples.isEmpty else { return }
        currentID = id
        samples = Array(values.suffix(capacity))
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
        // A shape of a trend cannot be spoken usefully sample by sample. Give the
        // figures that actually answer "how fast, and is it holding up?" — the
        // live rate sits beside the graph and is labelled separately.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recent throughput")
        .accessibilityValue(spokenSummary)
    }

    /// Peak and average over the window — the two numbers a sighted user reads
    /// off the curve's height and its general level.
    private var spokenSummary: String {
        guard !samples.isEmpty else { return "No samples yet" }
        let peak = samples.max() ?? 0
        let mean = samples.reduce(0, +) / Double(samples.count)
        return "average \(A11y.speed(mean)), peak \(A11y.speed(peak)), over the last \(samples.count) seconds"
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

/// A ↓ / ↑ speed readout — thin wrapper over ``SpeedStat`` for existing call sites.
struct DetailSpeedStat: View {
    let symbol: String
    let speed: Double
    let color: Color
    var size: CGFloat = 12.5

    var body: some View {
        SpeedStat(symbol: symbol, speed: speed, color: color, size: size)
    }
}

/// The coloured status dot + label ("Downloading", "Paused · 32%", …).
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
        // The dot restates the adjacent word in colour; the word is the
        // non-colour equivalent WCAG 1.4.1 asks for, and the only one spoken.
        .a11yGroup(label: "Status", value: task.accessibilityStatusName)
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
            button("Folder", "folder",
                   spoken: "Show \(task.name) in Finder") { vm.revealInFinder(task) }
            button("Copy", "doc.on.doc",
                   spoken: "Copy source link for \(task.name)") { vm.copyToPasteboard(task.sourceLocator) }
            if !fill { Spacer(minLength: 0) }
        }
    }

    @ViewBuilder private var primary: some View {
        if task.status.isActive {
            button("Pause", "pause.fill", spoken: "Pause \(task.name)", prominent: true) { vm.pause(task.id) }
        } else if task.status == .paused || task.status == .queued {
            button("Resume", "play.fill", spoken: "Resume \(task.name)", prominent: true) { vm.resume(task.id) }
        } else if case .failed = task.status {
            button("Retry", "arrow.clockwise", spoken: "Retry \(task.name)", prominent: true) { vm.retry(task.id) }
        }
    }

    /// `spoken` names the download the command acts on. The visible titles are
    /// one word each because the bar is 340pt wide in the right dock; that is
    /// fine to read and ambiguous to hear, since the panel's subject is
    /// established well above these buttons.
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
