import SwiftUI
import AppKit
import GoelCore

// The row primitives every area draws a download with. Names and initialisers are the old
// ones (Detail, the menu bar and the add sheet use them); the drawing is Studio's.

/// A file-type artwork tile at any size: the type's two-stop tint, its pattern and its glyph.
/// For the standard sizes prefer `StudioFileArtwork`; this one takes a free size.
struct FileTypeIcon: View {
    let type: FileType
    var size: CGFloat = 30

    var body: some View {
        let kind = StudioArtKind(type)
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        ZStack {
            StudioArtworkFill(kind: kind)
                .clipShape(shape)
            shape.strokeBorder(Studio.Palette.artHighlight, lineWidth: 1)
            StudioArtGlyph(kind: kind, size: size * 0.47)
                .foregroundStyle(Studio.Palette.artInk)
        }
        .frame(width: size, height: size)
        .a11yDecorative()
    }
}

/// A task's thin progress bar, coloured by state; a magnet fetching metadata sweeps instead.
/// No sweep-in on appear: rows scroll in and out of a list, and re-growing every bar as it
/// scrolled back into view read as progress resetting.
struct MiniProgressBar: View {
    let task: DownloadTask
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Studio.Palette.track)
                if task.status == .requestingMetadata {
                    IndeterminateBar(tint: Studio.Palette.accent)
                } else {
                    Capsule()
                        .fill(StudioProgressTone(task: task).color)
                        .frame(width: max(0, geo.size.width * task.fractionCompleted))
                }
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.updatesFrequently)
        .accessibilityLabel(L10n.t("Progress"))
        .accessibilityValue(task.status == .requestingMetadata
                            ? L10n.t("Requesting information")
                            : task.accessibilityProgressValue)
    }
}

/// "Working, amount unknown". A static capsule at 40% read as 40% progress, so this sweeps a short
/// highlight across the track instead; under Reduce Motion (and in snapshots) it holds still as
/// diagonal stripes, which read as "in progress" without claiming a fraction.
struct IndeterminateBar: View {
    let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.studioStillFrames) private var stillFrames
    /// A list can hold many of these; one scrolled out of view (or in a closed window) must not keep
    /// asking for frames.
    @State private var isVisible = false

    /// Capped: an uncapped `.animation` timeline redraws each row at the display's full refresh rate,
    /// which for a highlight this soft is only wasted frames.
    static let frameInterval: TimeInterval = 1.0 / 30

    /// One sweep, left edge to right edge.
    static let period: TimeInterval = 1.2
    /// The highlight's share of the track.
    static let bandFraction: CGFloat = 0.3

    /// The band's leading edge at `time`, as a fraction of the track: it starts fully off the left
    /// and ends fully off the right, so the sweep wraps without a visible jump.
    static func bandOffset(at time: TimeInterval) -> CGFloat {
        let phase = CGFloat(time.truncatingRemainder(dividingBy: period) / period)
        return -bandFraction + phase * (1 + bandFraction)
    }

    var body: some View {
        GeometryReader { geo in
            if reduceMotion || stillFrames {
                stripes(size: geo.size)
            } else {
                TimelineView(.animation(minimumInterval: Self.frameInterval, paused: !isVisible)) { context in
                    band(width: geo.size.width)
                        .offset(x: geo.size.width
                                * Self.bandOffset(at: context.date.timeIntervalSinceReferenceDate))
                }
            }
        }
        .clipShape(Capsule())
        .a11yDecorative()
        .onAppear { isVisible = true }
        .onDisappear { isVisible = false }
    }

    private func band(width: CGFloat) -> some View {
        Capsule()
            .fill(LinearGradient(colors: [tint.opacity(0), tint, tint.opacity(0)],
                                 startPoint: .leading, endPoint: .trailing))
            .frame(width: width * Self.bandFraction)
    }

    /// 45° stripes, spaced by the bar's height so they stay diagonal at any thickness.
    private func stripes(size: CGSize) -> some View {
        Path { path in
            let step = max(size.height * 2, 4)
            var x = -size.height
            while x < size.width + size.height {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                path.addLine(to: CGPoint(x: x + size.height + step / 2, y: 0))
                path.addLine(to: CGPoint(x: x + step / 2, y: size.height))
                path.closeSubpath()
                x += step
            }
        }
        .fill(tint.opacity(0.7))
    }
}

/// What a row's state button does. One glyph used to mean four things in the same grey; now the
/// action decides the tint, a failure gets a word, and a finished file gets no button at all
/// (double-click and Return already open it) unless the file went missing.
enum RowStateAction: Equatable {
    case pause, resume, retry, locate

    /// Nil: nothing worth a button (a completed download whose file is still there).
    init?(task: DownloadTask) {
        switch task.status {
        case .completed:
            guard task.isFileMissing else { return nil }
            self = .locate
        case .failed: self = .retry
        case .paused, .queued: self = .resume
        default: self = .pause
        }
    }

    var symbol: String {
        switch self {
        case .pause: return "pause.fill"
        case .resume: return "play.fill"
        case .retry: return "arrow.clockwise"
        case .locate: return "magnifyingglass"
        }
    }

    var title: String {
        switch self {
        case .pause: return L10n.t("Pause")
        case .resume: return L10n.t("Resume")
        case .retry: return L10n.t("Retry")
        case .locate: return L10n.t("Locate File…")
        }
    }

    /// Resume, Retry and Locate ask for the user; Pause is only offered on hover or selection.
    var wantsAttention: Bool { self != .pause }

    var tone: StudioTone {
        switch self {
        case .pause: return .neutral
        case .resume: return .accent
        case .retry: return .bad
        case .locate: return .warn
        }
    }

    @MainActor
    func perform(on task: DownloadTask, vm: AppViewModel) {
        switch self {
        case .locate: vm.locateMissingFile(task)
        case .retry: vm.retry(task.id)
        case .resume: vm.resume(task.id)
        case .pause: vm.pause(task.id)
        }
    }
}

/// The row's state button: a tinted 24 pt circle, or a "Retry" capsule for a failure.
/// `vm` is a plain reference, not observed — observing re-renders every row on each publish.
struct StateButton: View {
    let task: DownloadTask
    let vm: AppViewModel
    var compact = false
    /// A round glyph even for Retry, for the list's fixed-width action column; the title stays
    /// in the tooltip and the VoiceOver label.
    var iconOnly = false

    var body: some View {
        if let action = RowStateAction(task: task) {
            Button { action.perform(on: task, vm: vm) } label: {
                if action == .retry && !iconOnly {
                    Label(action.title, systemImage: action.symbol)
                } else {
                    Image(systemName: action.symbol)
                }
            }
            .buttonStyle(DownloadStateButtonStyle(tone: action.tone, isCapsule: action == .retry && !iconOnly,
                                                  side: compact ? 20 : 24))
            .help(action.title)
            .a11yButton(L10n.t("%1$@ %2$@", action.title, task.name))
        } else {
            // Keeps names in line with the rows that do have a button.
            Color.clear.frame(width: compact ? 20 : 24, height: compact ? 20 : 24).a11yDecorative()
        }
    }
}

/// Soft tinted circle (or capsule) with hover and keyboard-focus feedback.
struct DownloadStateButtonStyle: ButtonStyle {
    var tone: StudioTone
    var isCapsule = false
    var side: CGFloat = 24

    func makeBody(configuration: Configuration) -> some View {
        DownloadStateButtonBody(configuration: configuration, style: self)
    }
}

private struct DownloadStateButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let style: DownloadStateButtonStyle

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @State private var hovered = false

    var body: some View {
        let foreground = style.tone == .neutral ? (hovered ? Studio.Palette.ink : Studio.Palette.ink2)
                                                : style.tone.foreground
        let fill = hovered || configuration.isPressed
            ? (style.tone == .neutral ? Studio.Palette.track : style.tone.foreground.opacity(0.22))
            : style.tone.background
        configuration.label
            .labelStyle(StudioButtonLabelStyle(spacing: Studio.Space.xxs, iconSize: 10.5))
            // The glyph is sized to its fixed circle, not to the text-size setting.
            .font(StudioFonts.font(.ui, size: style.isCapsule ? 11.5 : style.side * 0.42,
                                   weight: style.isCapsule ? 650 : 700))
            .foregroundStyle(foreground)
            .padding(.horizontal, style.isCapsule ? 9 : 0)
            .frame(minWidth: style.side, minHeight: style.side)
            .frame(width: style.isCapsule ? nil : style.side, height: style.side)
            .background(Capsule().fill(fill))
            .studioFocusRing(isFocused, shape: Capsule())
            .contentShape(Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovered = isEnabled && $0 }
            .animation(Studio.Motion.quick, value: hovered)
    }
}
