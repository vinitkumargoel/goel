import Foundation
import GoelCore

/// The words and grouping of download banners, kept free of UserNotifications so it can be tested.
enum NotificationPlanning {

    /// Completions that land this close together share one "N downloads finished" banner.
    static let batchWindow: TimeInterval = 3

    struct Finished: Equatable {
        let taskID: UUID
        let name: String
    }

    enum CompletionBanner: Equatable {
        case single(Finished)
        case summary(count: Int, body: String)
    }

    /// One finish keeps its own banner (with Show in Finder / Open); several become a summary.
    static func completionBanner(for finished: [Finished]) -> CompletionBanner? {
        guard let first = finished.first else { return nil }
        guard finished.count > 1 else { return .single(first) }
        return .summary(count: finished.count, body: summaryBody(names: finished.map(\.name)))
    }

    /// "a.zip, b.iso and 3 more" — the first two names, then a count.
    static func summaryBody(names: [String]) -> String {
        let shown = names.prefix(2)
        let rest = names.count - shown.count
        let listed = shown.joined(separator: ", ")
        return rest > 0 ? L10n.t("%1$@ and %2$d more", listed, rest) : listed
    }

    static func summaryTitle(count: Int) -> String {
        L10n.t("%d downloads finished", count)
    }

    static func failureTitle(name: String) -> String {
        L10n.t("Couldn’t download “%@”", name)
    }

    /// Why, in the words the failure card uses: the advice when there is some, else the error itself.
    static func failureBody(for status: DownloadStatus) -> String {
        guard case .failed(let error) = status else { return L10n.t("The download stopped with an error.") }
        // An unrecognised error's own text beats the card's generic "something went wrong" hint.
        if case .unknown(let message) = error, !FailureAdvice.looksLikeDiskFull(message) { return error.message }
        return FailureAdvice.hint(for: error) ?? error.message
    }

    /// Tasks that just turned into `.completed` or `.failed`. A task with no previous status is
    /// new to this snapshot (a restore, or an add that finished instantly) and never counts.
    static func transitions(_ snapshot: [DownloadTask],
                            previous: [DownloadTask.ID: DownloadStatus]) -> (completed: [DownloadTask], failed: [DownloadTask]) {
        var completed: [DownloadTask] = []
        var failed: [DownloadTask] = []
        for task in snapshot {
            guard let before = previous[task.id], before != task.status else { continue }
            switch task.status {
            case .completed: completed.append(task)
            case .failed: if case .failed = before {} else { failed.append(task) }
            default: break
            }
        }
        return (completed, failed)
    }
}

/// Holds completion banners for ``NotificationPlanning/batchWindow`` so a burst of finishes
/// becomes one summary instead of a stack of banners.
@MainActor
final class CompletionBannerBatcher {
    private var pending: [NotificationPlanning.Finished] = []
    private var flushTask: Task<Void, Never>?
    private let window: TimeInterval

    init(window: TimeInterval = NotificationPlanning.batchWindow) {
        self.window = window
    }

    func add(_ finished: [NotificationPlanning.Finished],
             post: @escaping @MainActor (NotificationPlanning.CompletionBanner) -> Void) {
        guard !finished.isEmpty else { return }
        pending.append(contentsOf: finished)
        guard flushTask == nil else { return }
        let window = self.window
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(window))
            guard let self else { return }
            let batch = self.pending
            self.pending = []
            self.flushTask = nil
            if let banner = NotificationPlanning.completionBanner(for: batch) { post(banner) }
        }
    }
}
