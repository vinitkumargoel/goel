import SwiftUI

// MARK: - Seek resolution

/// The outcome of a scrub gesture: where the playhead is actually allowed to go, and whether the
/// user asked for somewhere it is not.
///
/// `didClamp` exists so the refusal is *visible*. Silently ignoring a drag past the write head is
/// the behaviour every other downloader ships and it is indistinguishable from a bug — the user
/// drags, nothing happens, and they cannot tell whether the app is broken or the bytes are simply
/// not there yet.
struct SeekResolution: Equatable, Sendable {
    /// 0…1 of the timeline. Never past the buffered edge.
    var fraction: Double
    /// The request reached past the buffered edge and was pulled back to it.
    var didClamp: Bool
}

// MARK: - ScrubMath

/// Every number the player derives, as pure functions over value types.
///
/// This is deliberately separate from the view: a simulator is not needed to prove that a buffer
/// lead is 33 minutes, that a seek clamps, or that a `nil` duration produces `nil` rather than
/// `inf`. `PlayerBufferTests` covers all of it.
///
/// The rule inherited from ``Fmt``: **nothing here may return a non-finite value.** Division is
/// guarded at every site, because `inf` and `NaN` render literally in a `Text`.
enum ScrubMath {

    /// Two fractions closer together than this are the same position. One part in a million of a
    /// timeline is well under a single frame of a multi-hour file, so a drag that lands exactly on
    /// the buffered edge is not reported as a clamp.
    static let epsilon = 1e-6

    /// How far into the timeline the downloaded bytes reach: `contiguousPrefix / totalBytes`.
    ///
    /// Emphatically **not** `receivedBytes / totalBytes` — with parallel segments the sum of the
    /// received bytes is separated from byte 0 by holes, and only the contiguous run at the front
    /// is actually playable. See ``Download/contiguousPrefix``.
    ///
    /// Returns `0` when the total is unknown or zero; clamps to `0…1`; never `NaN`.
    static func bufferedFraction(contiguousPrefix: Int64, totalBytes: Int64?) -> Double {
        guard let totalBytes, totalBytes > 0 else { return 0 }
        let fraction = Double(max(0, contiguousPrefix)) / Double(totalBytes)
        guard fraction.isFinite else { return 0 }
        return min(max(fraction, 0), 1)
    }

    /// Resolves a requested scrub position against the buffered edge.
    ///
    /// Both inputs are clamped to `0…1` first, so a gesture that runs off either end of the track
    /// resolves to a real position rather than a negative or out-of-range one.
    static func resolveSeek(fraction requested: Double, bufferedEdge: Double) -> SeekResolution {
        let edge = clamped(bufferedEdge)
        guard requested.isFinite else { return SeekResolution(fraction: 0, didClamp: false) }
        let wanted = clamped(requested)
        if wanted > edge + epsilon {
            return SeekResolution(fraction: edge, didClamp: true)
        }
        return SeekResolution(fraction: wanted, didClamp: false)
    }

    /// The byte offset the playhead corresponds to, assuming a constant average bitrate.
    ///
    /// An approximation, and the right one: the alternative is parsing the sample tables out of
    /// `moov` to find the exact offset of a presentation time, which buys precision the *stats
    /// card* — a number rounded to whole minutes — cannot spend.
    ///
    /// Returns `0` when the size or duration is unknown.
    static func playheadBytes(position: TimeInterval, duration: TimeInterval, totalBytes: Int64?) -> Int64 {
        guard let totalBytes, totalBytes > 0,
              duration.isFinite, duration > 0,
              position.isFinite
        else { return 0 }
        let fraction = min(max(position / duration, 0), 1)
        let bytes = Double(totalBytes) * fraction
        guard bytes.isFinite else { return 0 }
        return Int64(bytes.rounded())
    }

    /// How many *seconds of media* the download is ahead of the playhead.
    ///
    /// `(contiguousPrefix − playheadBytes) / (totalBytes / duration)` — the denominator being the
    /// file's average bytes per second of media. Minutes are what a person can act on; bytes are
    /// not. "Buffer: +33 min" tells you that you can put the phone in your pocket.
    ///
    /// Returns `nil` — never `inf` — when the size or the duration is unknown or zero, which is
    /// exactly the state the player is in for the first second of every transfer.
    static func bufferLeadSeconds(
        contiguousPrefix: Int64,
        playheadBytes: Int64,
        totalBytes: Int64?,
        duration: TimeInterval
    ) -> TimeInterval? {
        guard let totalBytes, totalBytes > 0, duration.isFinite, duration > 0 else { return nil }
        let bytesPerSecond = Double(totalBytes) / duration
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return nil }
        let lead = Double(contiguousPrefix - playheadBytes) / bytesPerSecond
        guard lead.isFinite else { return nil }
        return max(0, lead)
    }

    /// The stats-card string: `+33 min`, `+45 s`, `+1 h 12 min`, or `—` when it is not knowable.
    ///
    /// Not in ``Fmt`` because it is the only surface in the app that expresses a *lead* rather than
    /// a remaining time, and the sign is part of the meaning.
    static func leadLabel(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return Fmt.placeholder }
        let whole = Int(min(seconds, 100 * 3600).rounded())
        if whole < 60 { return "+\(whole) s" }
        if whole < 3600 { return "+\(whole / 60) min" }
        return "+\(whole / 3600) h \((whole % 3600) / 60) min"
    }

    private static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

// MARK: - BufferScrubber

/// The three-state scrubber. The system transport controls cannot draw this, which is the whole
/// reason it exists.
///
/// * **played** — solid `label1` (`#fff` in the app's dark identity)
/// * **buffered** — `label1` at 26 %: downloaded, not yet watched, safe to skip into
/// * **remainder** — ``Theme/Color/idleTrack``: not on disk, and therefore not reachable
///
/// The gesture stops at the buffered edge. A seek past it would hand `AVPlayer` a time whose bytes
/// do not exist, and it would sit there buffering until the download caught up — a stall that
/// looks exactly like a hang. So the knob refuses to follow the finger, turns ember, the trailing
/// timecode swaps for the buffered edge, and a warning haptic fires. The refusal is the feature.
struct BufferScrubber: View {

    /// Total media duration in seconds. `0` while the asset is still opening.
    let duration: TimeInterval
    /// Current playhead in seconds.
    let position: TimeInterval
    /// `contiguousPrefix / totalBytes`, 0…1.
    let bufferedFraction: Double
    /// `false` while the asset cannot be scrubbed at all (not open, or failed).
    var isEnabled: Bool = true
    /// Called on release, and on every accessibility increment, with an already-clamped time.
    let onSeek: (TimeInterval) -> Void

    /// Where the knob sits *during* a drag. `nil` means "follow the player".
    @State private var dragFraction: Double?
    @State private var isClamped = false
    /// Bumped on every fresh clamp so `sensoryFeedback` fires once per refusal, not per frame.
    @State private var clampTick = 0

    var body: some View {
        VStack(spacing: PlayerMetric.timeRowSpacing) {
            track
            timecodes
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback position")
        .accessibilityValue(spokenValue)
        .accessibilityHint("Adjust to move by \(Int(PlayerMetric.accessibilityStep)) seconds. "
            + "The playhead cannot pass the downloaded edge.")
        .accessibilityAdjustableAction(adjust)
        .sensoryFeedback(.warning, trigger: clampTick)
    }

    // MARK: Track

    private var track: some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 1)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.Color.idleTrack)
                    .frame(height: Theme.Metric.scrubberTrack)
                Capsule()
                    .fill(Theme.Color.label1.opacity(PlayerMetric.bufferedTrackOpacity))
                    .frame(width: width * bufferedEdge, height: Theme.Metric.scrubberTrack)
                Capsule()
                    .fill(Theme.Color.label1)
                    .frame(width: width * playedFraction, height: Theme.Metric.scrubberTrack)
                knob
                    .offset(x: width * playedFraction - Theme.Metric.scrubberKnob / 2)
            }
            .frame(width: width, height: geometry.size.height, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(drag(width: width))
        }
        // The bar is 6 pt and the mockup's rhythm depends on that, but a 6 pt control is not a
        // 44 pt hit target. Lay out at 44, then subtract the difference back out so the *rendered*
        // and *hit-tested* box stays 44 while the row occupies the knob's height in the stack.
        .frame(height: Theme.Metric.minHitTarget)
        .padding(.vertical, -(Theme.Metric.minHitTarget - Theme.Metric.scrubberKnob) / 2)
    }

    private var knob: some View {
        Circle()
            .fill(isClamped ? Theme.Color.ember : Theme.Color.label1)
            .frame(width: Theme.Metric.scrubberKnob, height: Theme.Metric.scrubberKnob)
            .scaleEffect(dragFraction == nil ? 1 : PlayerMetric.knobDragScale)
            .animation(.easeOut(duration: PlayerMetric.knobResponse), value: isClamped)
            .animation(.easeOut(duration: PlayerMetric.knobResponse), value: dragFraction == nil)
    }

    // MARK: Timecodes

    private var timecodes: some View {
        HStack(spacing: PlayerMetric.timeRowSpacing) {
            Text(Fmt.duration(displayedSeconds))
            Spacer(minLength: PlayerMetric.timeRowSpacing)
            if isClamped {
                // The clamp said out loud, in the one place the eye is already looking.
                Text("Downloaded to \(Fmt.duration(bufferedSeconds))")
                    .foregroundStyle(Theme.Color.ember)
            } else {
                Text(Fmt.remaining(max(0, duration - displayedSeconds)))
            }
        }
        .font(Theme.Typo.caption)
        .monospacedDigit()
        .foregroundStyle(Theme.Color.label2)
        .lineLimit(1)
        .minimumScaleFactor(PlayerMetric.timecodeMinimumScale)
    }

    // MARK: Gesture

    private func drag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isEnabled else { return }
                apply(x: value.location.x, width: width, commit: false)
            }
            .onEnded { value in
                guard isEnabled else { return }
                apply(x: value.location.x, width: width, commit: true)
            }
    }

    private func apply(x: CGFloat, width: CGFloat, commit: Bool) {
        let result = ScrubMath.resolveSeek(fraction: Double(x / width), bufferedEdge: bufferedEdge)
        dragFraction = result.fraction
        if result.didClamp != isClamped {
            isClamped = result.didClamp
            if result.didClamp { clampTick += 1 }
        }
        guard commit else { return }
        onSeek(result.fraction * max(duration, 0))
        dragFraction = nil
        isClamped = false
    }

    private func adjust(_ direction: AccessibilityAdjustmentDirection) {
        guard isEnabled, duration > 0 else { return }
        let step: TimeInterval
        switch direction {
        case .increment: step = PlayerMetric.accessibilityStep
        case .decrement: step = -PlayerMetric.accessibilityStep
        @unknown default: return
        }
        let target = max(0, position + step)
        let result = ScrubMath.resolveSeek(fraction: target / duration, bufferedEdge: bufferedEdge)
        if result.didClamp { clampTick += 1 }
        onSeek(result.fraction * duration)
    }

    // MARK: Derived

    private var bufferedEdge: Double {
        guard bufferedFraction.isFinite else { return 0 }
        return min(max(bufferedFraction, 0), 1)
    }

    private var playedFraction: Double {
        if let dragFraction { return dragFraction }
        guard duration > 0, position.isFinite else { return 0 }
        return min(max(position / duration, 0), 1)
    }

    private var displayedSeconds: TimeInterval {
        dragFraction == nil ? max(0, position) : playedFraction * max(duration, 0)
    }

    private var bufferedSeconds: TimeInterval { bufferedEdge * max(duration, 0) }

    private var spokenValue: String {
        let elapsed = Fmt.duration(displayedSeconds)
        guard duration > 0 else { return elapsed }
        var value = "\(elapsed) of \(Fmt.duration(duration))"
        if bufferedEdge < 1 - ScrubMath.epsilon {
            value += ", downloaded to \(Fmt.duration(bufferedSeconds))"
        }
        return value
    }
}

// MARK: - Previews

#Preview("Playing at 23% downloaded") {
    VStack {
        BufferScrubber(
            duration: 2460,
            position: 222,
            bufferedFraction: 0.23,
            onSeek: { _ in }
        )
    }
    .padding(.horizontal, PlayerMetric.scrubGutter)
    .frame(maxHeight: .infinity)
    .background(Theme.Color.ground)
    .preferredColorScheme(.dark)
}

#Preview("Fully downloaded") {
    VStack {
        BufferScrubber(
            duration: 2460,
            position: 1230,
            bufferedFraction: 1,
            onSeek: { _ in }
        )
    }
    .padding(.horizontal, PlayerMetric.scrubGutter)
    .frame(maxHeight: .infinity)
    .background(Theme.Color.ground)
    .preferredColorScheme(.dark)
}
