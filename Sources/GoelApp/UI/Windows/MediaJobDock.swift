import AppKit
import SwiftUI
import GoelCore

/// Conversion jobs, docked bottom-right over the main window: up to five cards, then
/// "+n more waiting".
struct MediaJobDock: View {

    @ObservedObject var center: MediaJobCenter

    var body: some View {
        MediaJobStack(jobs: center.jobs, isHidden: center.isDockHidden, center: center)
    }
}

/// The dock's cards for a given list of jobs (the dock passes the centre's; snapshots pass samples).
struct MediaJobStack: View {
    let jobs: [MediaJobCenter.Job]
    var isHidden = false
    let center: MediaJobCenter

    static let visibleLimit = 5

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shown = jobs.prefix(isHidden ? 0 : Self.visibleLimit)
        let overflow = jobs.count - shown.count
        VStack(alignment: .trailing, spacing: Studio.Space.s) {
            ForEach(shown) { job in
                MediaJobCard(job: job, center: center)
                    .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            }
            if overflow > 0, !isHidden {
                Text(L10n.t("+%d more waiting", overflow))
                    .studioFont(.caption.weight(600))
                    .foregroundStyle(Studio.Palette.ink2)
                    .padding(.horizontal, Studio.Space.sm)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Studio.Palette.cardRaised).studioElevation(.raised))
                    .overlay(Capsule().strokeBorder(Studio.Palette.cardEdge, lineWidth: 1))
            }
        }
        .padding(.trailing, Studio.Space.ml)
        .padding(.bottom, 52)
        .frame(width: 344)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: jobs.map(\.id))
    }
}

/// One conversion: what it makes, where it is, and the actions its state allows.
struct MediaJobCard: View {

    let job: MediaJobCenter.Job
    let center: MediaJobCenter

    @State private var showsDetail = false

    private var presentation: MediaJobPresentation { MediaJobPresentation(job: job) }

    var body: some View {
        let info = presentation
        VStack(alignment: .leading, spacing: Studio.Space.s) {
            HStack(alignment: .top, spacing: Studio.Space.sm) {
                artwork(info)
                VStack(alignment: .leading, spacing: Studio.Space.hair) {
                    Text(info.title)
                        .studioFont(.bodyStrong)
                        .foregroundStyle(Studio.Palette.ink)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(info.subtitle)
                        .studioFont(.caption)
                        .foregroundStyle(info.tone == .neutral || info.tone == .accent
                                         ? Studio.Palette.ink3 : info.tone.foreground)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(info.title)
                .accessibilityValue(info.spokenStatus)
                .accessibilityAddTraits(.updatesFrequently)
                closeButton(info)
            }
            progress
            if showsDetail, !job.log.isEmpty { detailBox }
            footer
        }
        .padding(Studio.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .studioSurface(.raised, radius: Studio.Radius.card, elevation: .floating)
        // Must stay `.contain`: collapsing the card drops the buttons out of the tree.
        .accessibilityElement(children: .contain)
    }

    private func artwork(_ info: MediaJobPresentation) -> some View {
        StudioFileArtwork(kind: info.kind, size: .s, isFaded: info.isQuiet)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: info.glyph)
                    .font(StudioFonts.font(.ui, size: 8.5, weight: 800))
                    .foregroundStyle(info.tone == .neutral ? Studio.Palette.ink2 : Studio.Palette.onAccent)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(info.tone == .neutral ? Studio.Palette.segment : info.tone.foreground))
                    .overlay(Circle().strokeBorder(Studio.Palette.cardRaised, lineWidth: 2))
                    .offset(x: 5, y: 5)
            }
            .padding(.trailing, Studio.Space.xxs)
            .padding(.bottom, Studio.Space.xxs)
            .accessibilityHidden(true)
    }

    private func closeButton(_ info: MediaJobPresentation) -> some View {
        StudioIconButton("xmark", label: info.closeHelp, size: .small) {
            if job.isStopStuck() {
                center.forceDismiss(job.id)
            } else if job.state.isLive {
                center.cancel(job.id)
            } else {
                center.dismiss(job.id)
            }
        }
        // Without the `isStopStuck()` clause a cancel that never lands strands the card.
        .disabled(job.state == .cancelling && !job.isStopStuck())
    }

    @ViewBuilder
    private var progress: some View {
        if let fraction = job.fraction, job.state.isLive {
            StudioLinearProgress(fraction: fraction,
                                 tone: job.state == .cancelling ? .paused : job.isStalled() ? .warn : .accent,
                                 height: StudioLinearProgress.thinHeight)
        } else if job.state.isLive {
            StudioLinearProgress(fraction: nil, tone: job.state == .cancelling ? .paused : .accent,
                                 height: StudioLinearProgress.thinHeight)
        }
    }

    private var detailBox: some View {
        ScrollView {
            Text(job.log)
                .studioFont(.monoSmall.size(10))
                .foregroundStyle(Studio.Palette.ink2)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 66)
        .padding(Studio.Space.xs)
        .background(Studio.Palette.well, in: RoundedRectangle(cornerRadius: Studio.Radius.small, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Studio.Radius.small, style: .continuous)
            .strokeBorder(Studio.Palette.hairline, lineWidth: 1))
    }

    @ViewBuilder
    private var footer: some View {
        switch job.state {
        case .finished(let url, _):
            actions {
                Button(L10n.t("Reveal in Finder"), systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .buttonStyle(.studio(.soft, size: .small))
                Button(L10n.t("Open")) { NSWorkspace.shared.open(url) }
                    .buttonStyle(.studio(.ghost, size: .small))
            }
        case .failed:
            actions {
                Button(showsDetail ? L10n.t("Hide Details") : L10n.t("Show Details")) { showsDetail.toggle() }
                    .buttonStyle(.studio(.ghost, size: .small))
                Button(L10n.t("Copy Details"), systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(job.log, forType: .string)
                }
                .buttonStyle(.studio(.ghost, size: .small))
            }
        case .running where job.isStalled():
            actions {
                Button(L10n.t("Cancel Job")) { center.cancel(job.id) }
                    .buttonStyle(.studio(.destructive, size: .small))
            }
        case .cancelling where job.isStopStuck():
            actions {
                Button(L10n.t("Stop Waiting")) { center.forceDismiss(job.id) }
                    .buttonStyle(.studio(.destructive, size: .small))
            }
        default:
            EmptyView()
        }
    }

    private func actions<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: Studio.Space.xs) {
            content()
            Spacer(minLength: 0)
        }
        .padding(.leading, 42)
    }
}

extension MediaJobCenter.Job {

    static func durationText(from start: Date, to end: Date?) -> String {
        let seconds = max(0, (end ?? Date()).timeIntervalSince(start))
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        let minutes = Int(seconds) / 60
        let remainder = Int(seconds) % 60
        return "\(minutes)m \(remainder)s"
    }
}
