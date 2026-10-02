import Foundation
import GoelCore

/// The words, glyph and tone a conversion job is shown with, in the dock and the menu bar.
struct MediaJobPresentation {
    let job: MediaJobCenter.Job
    var now = Date()

    /// The artwork family of what the job produces.
    var kind: StudioArtKind {
        switch job.kind {
        case .extractAudio: return .audio
        case .convert:
            return StudioArtKind(FileType.classify(fileName: job.input.lastPathComponent, isTorrent: false))
        }
    }

    /// Cancelled and queued jobs draw their artwork faded.
    var isQuiet: Bool {
        switch job.state {
        case .queued, .cancelled: return true
        case .cancelling: return !job.isStopStuck(now: now)
        default: return false
        }
    }

    var title: String {
        switch job.state {
        case .cancelling:
            return job.isStopStuck(now: now) ? L10n.t("%@ — won’t stop", job.kind.activeTitle)
                                             : job.kind.activeTitle
        case .queued, .running:
            return job.isStalled(now: now) ? L10n.t("%@ — not progressing", job.kind.activeTitle)
                                           : job.kind.activeTitle
        case .finished:  return job.kind.finishedTitle
        case .failed:
            // Only the leading word drops its capital: "Converting to MP4" keeps its "MP4".
            let active = job.kind.activeTitle
            return L10n.t("Couldn’t finish %@", L10n.midSentence(String(active.prefix(1))) + active.dropFirst())
        case .cancelled: return L10n.t("Cancelled")
        }
    }

    var subtitle: String {
        switch job.state {
        case .queued:
            return L10n.t("Waiting — %@", job.sourceName)
        case .cancelling:
            guard job.isStopStuck(now: now) else { return L10n.t("Stopping…") }
            let waiting = MediaJobCenter.Job.durationText(from: job.cancelRequestedAt ?? job.startedAt, to: now)
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
            if job.isStalled(now: now) {
                let since = MediaJobCenter.Job.durationText(from: job.lastAdvance, to: now)
                return L10n.t("No progress for %@ · ffmpeg may be stuck", since)
            }
            var pieces: [String] = []
            if let fraction = job.fraction {
                pieces.append("\(Int((fraction * 100).rounded()))%")
            } else {
                pieces.append(L10n.t("length unknown"))
                pieces.append(L10n.t("%@ elapsed", MediaJobCenter.Job.durationText(from: job.startedAt, to: now)))
            }
            if job.bytesWritten > 0 { pieces.append(job.bytesWritten.byteString) }
            if let eta = job.eta { pieces.append(L10n.t("~%@ left", DownloadTask.etaString(eta))) }
            if let speed = job.speed { pieces.append(String(format: "%.1f×", speed)) }
            return pieces.joined(separator: " · ")
        }
    }

    var spokenStatus: String {
        switch job.state {
        case .queued:     return L10n.t("Waiting to start")
        case .cancelling:
            return job.isStopStuck(now: now) ? L10n.t("Still stopping. ffmpeg has not exited.") : L10n.t("Stopping")
        case .cancelled:
            return job.removedPartial ? L10n.t("Cancelled, partial file removed")
                                      : L10n.t("Cancelled before anything was written")
        case .failed(let message): return L10n.t("Failed. %@", message)
        case .finished(let url, _): return L10n.t("Finished. Saved %@", url.lastPathComponent)
        case .running:
            if job.isStalled(now: now) { return L10n.t("Not progressing. ffmpeg may be stuck.") }
            guard let fraction = job.fraction else { return L10n.t("In progress, length unknown") }
            return A11y.sentence(A11y.percent(fraction), A11y.eta(job.eta))
        }
    }

    var glyph: String {
        switch job.state {
        case .queued:     return "clock"
        case .running:    return job.isStalled(now: now) ? "exclamationmark" : "arrow.left.arrow.right"
        case .cancelling: return job.isStopStuck(now: now) ? "exclamationmark" : "stop.fill"
        case .finished:   return "checkmark"
        case .failed:     return "exclamationmark"
        case .cancelled:  return "slash.circle"
        }
    }

    var tone: StudioTone {
        switch job.state {
        case .finished:   return .good
        case .failed:     return .bad
        case .cancelled, .queued: return .neutral
        case .running:    return job.isStalled(now: now) ? .warn : .accent
        case .cancelling: return job.isStopStuck(now: now) ? .warn : .neutral
        }
    }

    var closeHelp: String {
        if job.isStopStuck(now: now) {
            return L10n.t("Stop waiting for %@", L10n.midSentence(job.kind.activeTitle))
        }
        return job.state.isLive ? L10n.t("Cancel this conversion") : L10n.t("Dismiss")
    }
}
