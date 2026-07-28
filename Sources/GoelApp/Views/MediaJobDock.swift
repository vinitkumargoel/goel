import AppKit
import SwiftUI
import GoelCore

struct MediaJobDock: View {

    @ObservedObject var center: MediaJobCenter

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
                Text(L10n.t("+%d more waiting", overflow))
                    .scaledFont(size: 10.5)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
            }
        }
        .padding(.trailing, 14)
        .padding(.bottom, 52)
        .frame(width: 344)
        .animation(.easeInOut(duration: 0.18), value: center.jobs.map(\.id))
    }
}

private struct MediaJobCard: View {

    let job: MediaJobCenter.Job
    @ObservedObject var center: MediaJobCenter

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
        // Must stay `.contain`: collapsing the card drops the buttons out of the tree.
        .accessibilityElement(children: .contain)
    }

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
                Spacer(minLength: 24)
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
        // Without the `isStopStuck()` clause a cancel that never lands strands the card.
        .disabled(job.state == .cancelling && !job.isStopStuck())
        .help(closeHelp)
        .accessibilityLabel(closeHelp)
    }

    private var closeHelp: String {
        if job.isStopStuck() { return L10n.t("Stop waiting for %@", L10n.t(job.kind.activeTitle).lowercased()) }
        return job.state.isLive ? L10n.t("Cancel this conversion") : L10n.t("Dismiss")
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
                Button(L10n.t("Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.link)
                Button(L10n.t("Open")) { NSWorkspace.shared.open(url) }
                    .buttonStyle(.link)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .scaledFont(size: 11)
        case .failed:
            HStack(spacing: 12) {
                Button(showsDetail ? L10n.t("Hide details") : L10n.t("Show details")) {
                    showsDetail.toggle()
                }
                .buttonStyle(.link)
                Button(L10n.t("Copy details")) {
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
                Button(L10n.t("Cancel this job")) { center.cancel(job.id) }
                    .buttonStyle(.link)
                Spacer(minLength: 0)
            }
            .scaledFont(size: 11)
        case .cancelling where job.isStopStuck():
            HStack(spacing: 12) {
                Button(L10n.t("Stop waiting")) { center.forceDismiss(job.id) }
                    .buttonStyle(.link)
                Spacer(minLength: 0)
            }
            .scaledFont(size: 11)
        default:
            EmptyView()
        }
    }

    private var title: String {
        switch job.state {
        case .cancelling:
            return job.isStopStuck() ? L10n.t("%@ — won’t stop", L10n.t(job.kind.activeTitle))
                                     : L10n.t(job.kind.activeTitle)
        case .queued, .running:
            return job.isStalled() ? L10n.t("%@ — not progressing", L10n.t(job.kind.activeTitle))
                                   : L10n.t(job.kind.activeTitle)
        case .finished:  return L10n.t(job.kind.finishedTitle)
        case .failed:    return L10n.t("Couldn’t finish %@", L10n.t(job.kind.activeTitle).lowercased())
        case .cancelled: return L10n.t("Cancelled")
        }
    }

    private var subtitle: String {
        switch job.state {
        case .queued:
            return L10n.t("Waiting — %@", job.sourceName)
        case .cancelling:
            guard job.isStopStuck() else { return L10n.t("Stopping…") }
            let waiting = MediaJobCenter.Job.durationText(from: job.cancelRequestedAt ?? job.startedAt,
                                                          to: Date())
            return L10n.t("ffmpeg hasn’t exited after %@ · the file may be on a stalled disk", waiting)
        case .cancelled:
            return job.removedPartial ? L10n.t("Partial file removed") : L10n.t("Nothing was written")
        case .failed(let message):
            return message
        case .finished(let url, let usedStreamCopy):
            let how = usedStreamCopy ? L10n.t("copied, no re-encode") : L10n.t("re-encoded")
            let took = MediaJobCenter.Job.durationText(from: job.startedAt, to: job.finishedAt)
            return "\(url.lastPathComponent) · \(how) · \(took)"
        case .running:
            if job.isStalled() {
                let since = MediaJobCenter.Job.durationText(from: job.lastAdvance, to: Date())
                return L10n.t("no progress for %@ · ffmpeg may be stuck", since)
            }
            var pieces: [String] = []
            if let fraction = job.fraction {
                pieces.append("\(Int((fraction * 100).rounded()))%")
            } else {
                pieces.append(L10n.t("length unknown"))
                pieces.append(L10n.t("%@ elapsed",
                                     MediaJobCenter.Job.durationText(from: job.startedAt, to: Date())))
            }
            if job.bytesWritten > 0 { pieces.append(job.bytesWritten.byteString) }
            if let eta = job.eta { pieces.append(L10n.t("~%@ left", DownloadTask.etaString(eta))) }
            if let speed = job.speed { pieces.append(String(format: "%.1f×", speed)) }
            return pieces.joined(separator: " · ")
        }
    }

    private var spokenStatus: String {
        switch job.state {
        case .queued:     return L10n.t("Waiting to start")
        case .cancelling:
            return job.isStopStuck() ? L10n.t("Still stopping. ffmpeg has not exited.") : L10n.t("Stopping")
        case .cancelled:
            return job.removedPartial ? L10n.t("Cancelled, partial file removed")
                                      : L10n.t("Cancelled before anything was written")
        case .failed(let message): return L10n.t("Failed. %@", message)
        case .finished(let url, _): return L10n.t("Finished. Saved %@", url.lastPathComponent)
        case .running:
            if job.isStalled() { return L10n.t("Not progressing. ffmpeg may be stuck.") }
            guard let fraction = job.fraction else { return L10n.t("In progress, length unknown") }
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

extension MediaJobCenter.Job {

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
