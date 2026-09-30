import Foundation
import SwiftUI

/// One transient message at the bottom of the window, optionally with a button (Undo, Retry).
struct Toast: Identifiable, Equatable {
    struct Action {
        let title: String
        let perform: @MainActor () -> Void
    }

    let id = UUID()
    let message: String
    let isError: Bool
    let action: Action?

    static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }

    /// Failures linger longer (a missed error is worse than a missed confirmation), and a toast
    /// with a button stays long enough to reach it.
    var dwell: TimeInterval {
        if action != nil { return 8 }
        return isError ? 5 : 2.4
    }
}

/// FIFO, not a single slot: two toasts posted in the same breath both get seen — the second
/// used to overwrite the first before it was ever drawn. Kept apart from the view model so a
/// toast redraws only the overlay that shows it.
@MainActor
final class ToastQueue: ObservableObject {

    @Published private(set) var current: Toast?
    private(set) var pending: [Toast] = []

    /// A burst beyond this drops its oldest waiting entries; errors are kept over confirmations.
    static let maxPending = 4
    /// With others waiting, a plain confirmation yields after this long instead of its full dwell.
    static let busyDwell: TimeInterval = 1.2

    private let autoAdvance: Bool
    private var generation = 0

    init(autoAdvance: Bool = true) {
        self.autoAdvance = autoAdvance
    }

    func show(_ message: String, isError: Bool = false, action: Toast.Action? = nil) {
        // The same words already on screen or queued add nothing but delay.
        if current?.message == message, current?.isError == isError, action == nil { return }
        if pending.contains(where: { $0.message == message && $0.isError == isError && $0.action == nil }),
           action == nil { return }
        let toast = Toast(message: message, isError: isError, action: action)
        guard current != nil else { present(toast); return }
        pending.append(toast)
        trimPending()
        // A confirmation that's been up long enough makes way for what's waiting.
        if autoAdvance, let shown = current, shown.action == nil, !shown.isError {
            scheduleExpiry(of: shown, after: Self.busyDwell)
        }
    }

    /// The visible toast's time is up (or the user dismissed it): the next one takes its place.
    func advance() {
        generation &+= 1
        if pending.isEmpty {
            current = nil
        } else {
            present(pending.removeFirst())
        }
    }

    /// Runs the button and retires the toast, so a second click can't fire it twice.
    func performAction() {
        guard let action = current?.action else { return }
        advance()
        action.perform()
    }

    private func present(_ toast: Toast) {
        generation &+= 1
        current = toast
        let dwell = pending.isEmpty || toast.action != nil || toast.isError ? toast.dwell : Self.busyDwell
        scheduleExpiry(of: toast, after: dwell)
    }

    private func scheduleExpiry(of toast: Toast, after seconds: TimeInterval) {
        guard autoAdvance else { return }
        let expected = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self, self.generation == expected, self.current?.id == toast.id else { return }
            self.advance()
        }
    }

    private func trimPending() {
        while pending.count > Self.maxPending {
            if let index = pending.firstIndex(where: { !$0.isError && $0.action == nil }) {
                pending.remove(at: index)
            } else {
                pending.removeFirst()
            }
        }
    }
}
