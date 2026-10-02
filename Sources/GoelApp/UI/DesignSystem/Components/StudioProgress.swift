import SwiftUI
import GoelCore

/// What a progress mark is coloured by (`.ring.paused`, `.ring.up`, `.bar.good`, …).
enum StudioProgressTone: CaseIterable, Sendable {
    case accent, paused, upload, good, warn, bad

    var color: Color {
        switch self {
        case .accent: return Studio.Palette.accent
        case .paused: return Studio.Palette.ink3
        case .upload: return Studio.Palette.upload
        case .good: return Studio.Palette.good
        case .warn: return Studio.Palette.warn
        case .bad: return Studio.Palette.bad
        }
    }

    /// The tone a task's progress is drawn in.
    init(task: DownloadTask) {
        self.init(StudioDownloadState(task: task))
    }

    init(_ state: StudioDownloadState) {
        switch state {
        case .downloading, .verifying, .requestingMetadata: self = .accent
        case .paused, .queued: self = .paused
        case .seeding: self = .upload
        case .completed: self = .good
        case .fileMissing: self = .warn
        case .failed: self = .bad
        }
    }
}

/// A circular progress arc (`.ring`). Determinate arcs sweep in from zero when they appear;
/// `fraction: nil` draws the indeterminate spinner. Both hold still under Reduce Motion.
///
///     StudioProgressArc(fraction: 0.62)                               // 46 pt, "62" inside
///     StudioProgressArc(fraction: 0.62, diameter: 86) { Image(systemName: "arrow.down") }
///     StudioProgressArc(fraction: nil, tone: .accent, diameter: 24)   // spinner
struct StudioProgressArc<Center: View>: View {
    var fraction: Double?
    var tone: StudioProgressTone = .accent
    var diameter: CGFloat = 46
    /// Defaults to the mockup's 4/40 of the diameter.
    var lineWidth: CGFloat?
    /// Spoken as the element's label; the value is the percentage.
    var accessibilityLabel: String = L10n.t("Progress")
    @ViewBuilder var center: () -> Center

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.studioStillFrames) private var stillFrames
    @State private var shown: Double = 0
    @State private var hasAppeared = false

    private var isStill: Bool { reduceMotion || stillFrames }
    private var stroke: CGFloat { lineWidth ?? max(2, diameter * 0.1) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Studio.Palette.track, lineWidth: stroke)
            if let fraction {
                Circle()
                    .trim(from: 0, to: CGFloat(max(0, min(1, isStill ? fraction : shown))))
                    .stroke(tone.color, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                StudioSpinnerArc(color: tone.color, lineWidth: stroke, still: isStill)
            }
            center()
        }
        .padding(stroke / 2)
        .frame(width: diameter, height: diameter)
        .onAppear {
            guard let fraction, !hasAppeared else { return }
            hasAppeared = true
            if isStill {
                shown = fraction
            } else {
                withAnimation(Studio.Motion.sweep) { shown = fraction }
            }
        }
        .onChange(of: fraction) { _, next in
            guard let next else { return }
            if isStill { shown = next } else { withAnimation(.easeOut(duration: 0.35)) { shown = next } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(fraction.map { A11y.percent($0) } ?? L10n.t("In progress"))
    }
}

extension StudioProgressArc where Center == StudioArcPercentLabel {
    /// The board card's arc: the whole percentage inside, no % sign below 86 pt (`.rw > b`).
    init(fraction: Double?, tone: StudioProgressTone = .accent, diameter: CGFloat = 46,
         lineWidth: CGFloat? = nil, accessibilityLabel: String = L10n.t("Progress")) {
        self.init(fraction: fraction, tone: tone, diameter: diameter, lineWidth: lineWidth,
                  accessibilityLabel: accessibilityLabel) {
            StudioArcPercentLabel(fraction: fraction, diameter: diameter)
        }
    }
}

/// The number inside an arc. Sized from the arc, not the text-size setting, so it always fits.
struct StudioArcPercentLabel: View {
    let fraction: Double?
    let diameter: CGFloat

    var body: some View {
        if let fraction {
            let percent = Int((max(0, min(1, fraction)) * 100).rounded())
            let big = diameter >= 86
            let size = diameter * (big ? 0.26 : 0.25)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(verbatim: "\(percent)")
                    // fixed-size: the number is sized to the arc's fixed diameter.
                    .font(StudioFonts.font(.display, size: size, weight: big ? 750 : 700, tabularNumbers: true))
                    .tracking(-size * (big ? 0.04 : 0.02))
                // Room for the unit from 60 pt up (the queue ring, the detail hero); a card's
                // 46 pt arc shows the bare number.
                if diameter >= 60 {
                    Text(verbatim: "%")
                        // fixed-size: the number is sized to the arc's fixed diameter.
                        .font(StudioFonts.font(.display, size: size * 0.47, weight: 600))
                }
            }
            .foregroundStyle(Studio.Palette.ink)
            .minimumScaleFactor(0.6)
            .lineLimit(1)
        }
    }
}

/// The indeterminate arc: a 22% sweep turning once every 1.6 s.
private struct StudioSpinnerArc: View {
    let color: Color
    let lineWidth: CGFloat
    let still: Bool

    var body: some View {
        if still {
            arc(.degrees(-90))
        } else {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                arc(.degrees(t.truncatingRemainder(dividingBy: 1.6) / 1.6 * 360 - 90))
            }
        }
    }

    private func arc(_ angle: Angle) -> some View {
        Circle()
            .trim(from: 0, to: 0.22)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(angle)
    }
}

/// A linear progress bar (`.bar`, 6 pt; `thin` 4 pt). `fraction: nil` slides a highlight
/// across the track, which holds still under Reduce Motion.
struct StudioLinearProgress: View {
    var fraction: Double?
    var tone: StudioProgressTone = .accent
    var height: CGFloat = 6
    var accessibilityLabel: String = L10n.t("Progress")

    static let thinHeight: CGFloat = 4

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.studioStillFrames) private var stillFrames
    @State private var shown: Double = 0

    private var isStill: Bool { reduceMotion || stillFrames }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Studio.Palette.track)
                if let fraction {
                    Capsule()
                        .fill(tone.color)
                        .frame(width: proxy.size.width * CGFloat(max(0, min(1, isStill ? fraction : shown))))
                } else {
                    StudioSlidingHighlight(color: tone.color, width: proxy.size.width, still: isStill)
                }
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
        .onAppear {
            guard let fraction else { return }
            if isStill { shown = fraction } else { withAnimation(Studio.Motion.sweep) { shown = fraction } }
        }
        .onChange(of: fraction) { _, next in
            guard let next else { return }
            if isStill { shown = next } else { withAnimation(.easeOut(duration: 0.35)) { shown = next } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(fraction.map { A11y.percent($0) } ?? L10n.t("In progress"))
    }
}

private struct StudioSlidingHighlight: View {
    let color: Color
    let width: CGFloat
    let still: Bool

    var body: some View {
        if still {
            bar(offset: width * 0.325)
        } else {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                // ease-in-out from -100% to +300% of the highlight's own width.
                let eased = 0.5 - cos(t * .pi) / 2
                bar(offset: -width * 0.35 + eased * width * 1.35)
            }
        }
    }

    private func bar(offset: CGFloat) -> some View {
        LinearGradient(colors: [color.opacity(0), color, color.opacity(0)], startPoint: .leading, endPoint: .trailing)
            .frame(width: width * 0.35)
            .offset(x: offset)
    }
}
