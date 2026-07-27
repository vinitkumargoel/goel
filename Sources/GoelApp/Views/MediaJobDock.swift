import AppKit
import SwiftUI
import GoelCore

/// The stack of conversion cards docked in the bottom-trailing corner of the
/// window.
///
/// This is the surface that was missing. Convert and Extract Audio previously
/// reported themselves through the app's single shared `toast` string — one line,
/// 2.4 seconds, overwritten by the next toast from anywhere in the app — so a
/// conversion that ran for six minutes was visible for the first four hundredth
/// of it. A card persists for the whole job, shows real progress, and carries the
/// cancel button that had nowhere to live before.
///
/// Deliberately **not** a row in the main download list: that list is bound to
/// `DownloadTask`s owned by the manager actor, and a conversion has no URL, no
/// network throughput, no resume, no retry and no persistence. Forcing one into
/// that model would mean either a counterfeit `DownloadTask` leaking into
/// History, the CLI and the portal API, or a variant enum every call site has to
/// unwrap. The dock is purely additive.
struct MediaJobDock: View {

    @ObservedObject var center: MediaJobCenter

    /// Cards drawn at once. The stack is an overlay on the window, so it cannot
    /// scroll and cannot grow — past about five it would cover the list it is
    /// reporting on. Successes clear themselves, so what accumulates here is
    /// failures and a queue, and the queue is summarised in one line instead.
    private static let visibleLimit = 5

    var body: some View {
        let shown = center.jobs.prefix(Self.visibleLimit)
        let overflow = center.jobs.count - shown.count
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(shown) { job in
                MediaJobCard(job: job, center: center)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            if overflow > 0 {
                Text("+\(overflow) more waiting")
                    .scaledFont(size: 10.5)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
            }
        }
        .padding(.trailing, 14)
        .padding(.bottom, 52)   // clear of the status bar
        .frame(width: 344)
        .animation(.easeInOut(duration: 0.18), value: center.jobs.map(\.id))
    }
}

// MARK: - One card

private struct MediaJobCard: View {

    let job: MediaJobCenter.Job
    @ObservedObject var center: MediaJobCenter

    /// Whether the raw ffmpeg output is expanded on a failed card.
    @State private var showsDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            summary
            if showsDetail, !job.log.isEmpty { detailBox }
            footer
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(accent.opacity(0.45)))
        .overlay(alignment: .topTrailing) { closeButton.padding(.top, 8).padding(.trailing, 8) }
        .shadow(radius: 10, y: 4)
        // A *container*, not one element. Collapsing the whole card into a single
        // accessibility element (`children: .ignore`) reads nicely and takes the
        // cancel, Reveal in Finder and Copy details buttons out of the tree
        // entirely — the card would be narrated and then be unusable. The status
        // half is grouped into one sentence below; the buttons stay siblings.
        .accessibilityElement(children: .contain)
    }

    // MARK: Pieces

    /// Everything that is text rather than action: glyph, title, numbers, bar.
    /// One accessibility element, read as a sentence and marked live so a state
    /// change is announced.
    private var summary: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: glyph)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 22, height: 22)
                    .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                    .a11yDecorative()
                Text(title)
                    .scaledFont(size: 12, weight: .semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 24)   // room for the close button in the overlay
            }
            Text(subtitle)
                .scaledFont(size: 10.5, design: .monospaced)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            progressBar
        }
        .a11yGroup(label: title, value: spokenStatus)
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// One button with three meanings, which is why its label changes: on a live
    /// job it stops the work, on a finished one it clears the card, and on a stop
    /// that is not completing it lets go of the job entirely.
    private var closeButton: some View {
        Button {
            if job.isStopStuck() {
                center.forceDismiss(job.id)
            } else if job.state.isLive {
                center.cancel(job.id)
            } else {
                center.dismiss(job.id)
            }
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        // Disabled only during the few seconds a stop should take. Past that
        // ``Job/isStopStuck()`` re-enables it as a force-dismiss, so a cancel that
        // never lands can't leave a card with no working control on it.
        .disabled(job.state == .cancelling && !job.isStopStuck())
        .help(closeHelp)
        .accessibilityLabel(closeHelp)
    }

    private var closeHelp: String {
        if job.isStopStuck() { return "Stop waiting for \(job.kind.activeTitle.lowercased())" }
        return job.state.isLive ? "Cancel this conversion" : "Dismiss"
    }

    @ViewBuilder
    private var progressBar: some View {
        if let fraction = job.fraction {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.10))
                    Capsule().fill(accent)
                        .frame(width: max(0, geo.size.width * fraction))
                }
            }
            .frame(height: 5)
        } else if job.state.isLive {
            // No declared duration — say so with an indeterminate bar rather than
            // inventing a percentage that would sit still and then jump to done.
            ProgressView()
                .progressViewStyle(.linear)
                .controlSize(.small)
        } else {
            Capsule().fill(accent.opacity(0.5)).frame(height: 5)
        }
    }

    private var detailBox: some View {
        ScrollView {
            Text(job.log)
                .scaledFont(size: 10, design: .monospaced)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 66)
        .padding(6)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var footer: some View {
        switch job.state {
        case .finished(let url, _):
            HStack(spacing: 12) {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.link)
                Button("Open") { NSWorkspace.shared.open(url) }
                    .buttonStyle(.link)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .scaledFont(size: 11)
        case .failed:
            HStack(spacing: 12) {
                Button(showsDetail ? "Hide details" : "Show details") {
                    showsDetail.toggle()
                }
                .buttonStyle(.link)
                Button("Copy details") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(job.log, forType: .string)
                }
                .buttonStyle(.link)
                .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .scaledFont(size: 11)
        case .running where job.isStalled():
            HStack(spacing: 12) {
                Button("Cancel this job") { center.cancel(job.id) }
                    .buttonStyle(.link)
                Spacer(minLength: 0)
            }
            .scaledFont(size: 11)
        case .cancelling where job.isStopStuck():
            // The one card the user cannot resolve by waiting. Say what letting go
            // does and does not do, rather than offering a button that implies the
            // process is being killed again — it already was.
            HStack(spacing: 12) {
                Button("Stop waiting") { center.forceDismiss(job.id) }
                    .buttonStyle(.link)
                Spacer(minLength: 0)
            }
            .scaledFont(size: 11)
        default:
            EmptyView()
        }
    }

    // MARK: Copy

    private var title: String {
        switch job.state {
        case .cancelling:
            return job.isStopStuck() ? "\(job.kind.activeTitle) — won’t stop"
                                     : job.kind.activeTitle
        case .queued, .running:
            return job.isStalled() ? "\(job.kind.activeTitle) — not progressing"
                                   : job.kind.activeTitle
        case .finished:  return job.kind.finishedTitle
        case .failed:    return "Couldn’t finish \(job.kind.activeTitle.lowercased())"
        case .cancelled: return "Cancelled"
        }
    }

    /// The monospaced second line: the numbers, in the order a person scans them.
    private var subtitle: String {
        switch job.state {
        case .queued:
            return "Waiting — \(job.sourceName)"
        case .cancelling:
            guard job.isStopStuck() else { return "Stopping…" }
            let waiting = MediaJobCenter.Job.durationText(from: job.cancelRequestedAt ?? job.startedAt,
                                                          to: Date())
            return "ffmpeg hasn’t exited after \(waiting) · the file may be on a stalled disk"
        case .cancelled:
            // Only claimed when it happened. A job cancelled while it was still
            // queued never wrote anything to remove.
            return job.removedPartial ? "Partial file removed" : "Nothing was written"
        case .failed(let message):
            return message
        case .finished(let url, let usedStreamCopy):
            let how = usedStreamCopy ? "copied, no re-encode" : "re-encoded"
            let took = MediaJobCenter.Job.durationText(from: job.startedAt, to: job.finishedAt)
            return "\(url.lastPathComponent) · \(how) · \(took)"
        case .running:
            if job.isStalled() {
                let since = MediaJobCenter.Job.durationText(from: job.lastAdvance, to: Date())
                return "no progress for \(since) · ffmpeg may be stuck"
            }
            var pieces: [String] = []
            if let fraction = job.fraction {
                pieces.append("\(Int((fraction * 100).rounded()))%")
            } else {
                pieces.append("length unknown")
                pieces.append(MediaJobCenter.Job.durationText(from: job.startedAt, to: Date()) + " elapsed")
            }
            if job.bytesWritten > 0 { pieces.append(job.bytesWritten.byteString) }
            if let eta = job.eta { pieces.append("~\(DownloadTask.etaString(eta)) left") }
            if let speed = job.speed { pieces.append(String(format: "%.1f×", speed)) }
            return pieces.joined(separator: " · ")
        }
    }

    /// What VoiceOver reads. Percentages are deliberately coarse: a live region
    /// that announces "39 percent… 40 percent…" forever is hostile.
    private var spokenStatus: String {
        switch job.state {
        case .queued:     return "Waiting to start"
        case .cancelling:
            return job.isStopStuck() ? "Still stopping. ffmpeg has not exited." : "Stopping"
        case .cancelled:
            return job.removedPartial ? "Cancelled, partial file removed"
                                      : "Cancelled before anything was written"
        case .failed(let message): return "Failed. \(message)"
        case .finished(let url, _): return "Finished. Saved \(url.lastPathComponent)"
        case .running:
            if job.isStalled() { return "Not progressing. ffmpeg may be stuck." }
            guard let fraction = job.fraction else { return "In progress, length unknown" }
            return A11y.sentence(A11y.percent(fraction), A11y.eta(job.eta))
        }
    }

    private var glyph: String {
        switch job.state {
        case .queued:     return "clock"
        case .running:    return job.isStalled() ? "exclamationmark.triangle.fill" : "waveform"
        case .cancelling: return job.isStopStuck() ? "exclamationmark.triangle.fill" : "stop.circle"
        case .finished:   return "checkmark.circle.fill"
        case .failed:     return "exclamationmark.triangle.fill"
        case .cancelled:  return "slash.circle"
        }
    }

    private var accent: Color {
        switch job.state {
        case .finished:   return Theme.green
        case .failed:     return Theme.red
        case .cancelled:  return .secondary
        case .running:    return job.isStalled() ? Theme.orange : Theme.accent
        case .cancelling: return job.isStopStuck() ? Theme.orange : .secondary
        case .queued:     return .secondary
        }
    }
}

// MARK: - Formatting

extension MediaJobCenter.Job {

    /// "34s" / "6m 12s" between two instants, for the elapsed and duration lines.
    static func durationText(from start: Date, to end: Date?) -> String {
        let seconds = max(0, (end ?? Date()).timeIntervalSince(start))
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        let minutes = Int(seconds) / 60
        let remainder = Int(seconds) % 60
        return "\(minutes)m \(remainder)s"
    }
}

#if DEBUG
#Preview("Media job dock") {
    let center = MediaJobCenter()
    return MediaJobDock(center: center)
        .frame(width: 380, height: 300)
}
#endif
