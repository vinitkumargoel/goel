import Foundation
import GoelCore

/// The words a finished download is summed up in: "2.9 GB · finished Today at 21:07" and
/// "4m 12s · avg 18 MB/s". The model records when a download was added and when it finished,
/// not when it first started moving, so "took" spans the whole wait from add to finish.
enum CompletionSummary {

    /// The bytes on disk: the declared size, or what arrived when the size was never known.
    static func size(of task: DownloadTask) -> Int64 {
        task.totalBytes ?? task.bytesDownloaded
    }

    static func finishedLine(bytes: Int64, completedAt: Date?,
                             locale: Locale = DisplayFormat.appLocale) -> String {
        let size = bytes > 0 ? bytes.byteString : nil
        guard let completedAt else { return size ?? L10n.t("Finished") }
        let when = L10n.t("finished %@", DisplayFormat.relativeDateTime(completedAt, locale: locale))
        return size.map { L10n.t("%1$@ · %2$@", $0, when) } ?? when
    }

    /// Seconds from add to finish; nil when either end is unknown or the clock ran backwards.
    static func elapsed(addedAt: Date, completedAt: Date?) -> TimeInterval? {
        guard let completedAt else { return nil }
        let seconds = completedAt.timeIntervalSince(addedAt)
        return seconds > 0 ? seconds : nil
    }

    /// "4m 12s · avg 18 MB/s", or just the duration when no bytes were counted.
    static func tookLine(bytes: Int64, addedAt: Date, completedAt: Date?,
                         locale: Locale = DisplayFormat.appLocale) -> String? {
        guard let seconds = elapsed(addedAt: addedAt, completedAt: completedAt) else { return nil }
        let duration = DisplayFormat.duration(seconds, locale: locale)
        guard bytes > 0 else { return duration }
        let average = (Double(bytes) / seconds).speedString
        return L10n.t("%1$@ · avg %2$@", duration, average)
    }
}
