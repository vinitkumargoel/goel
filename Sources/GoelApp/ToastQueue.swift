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

    /// A burst beyond this drops its oldest waiting entries; errors are kept over confirmations,
    /// and toasts with a button over both.
    static let maxPending = 4
    /// With others waiting, a plain confirmation yields after this long instead of its full dwell.
    static let busyDwell: TimeInterval = 1.2

    private let autoAdvance: Bool
    private var generation = 0
    /// Here, not in the overlay: the main window and Settings both draw one, and VoiceOver
    /// heard every toast twice.
    private let announce: @MainActor (String) -> Void

    init(autoAdvance: Bool = true, announce: @escaping @MainActor (String) -> Void = { A11yAnnouncer.announce($0) }) {
        self.autoAdvance = autoAdvance
        self.announce = announce
    }

    /// Returns the toast's id so its poster can retire it (⌘Z retires an Undo toast); nil when deduplicated.
    @discardableResult
    func show(_ message: String, isError: Bool = false, action: Toast.Action? = nil) -> Toast.ID? {
        // The same words already on screen or queued add nothing but delay.
        if current?.message == message, current?.isError == isError, action == nil { return nil }
        if pending.contains(where: { $0.message == message && $0.isError == isError && $0.action == nil }),
           action == nil { return nil }
        let toast = Toast(message: message, isError: isError, action: action)
        guard let shown = current else { present(toast); return toast.id }
        if action != nil {
            // An Undo belongs next to what it undoes: it jumps the line. What it displaces waits
            // at the front only if it still matters (an error, or another button).
            if shown.isError || shown.action != nil { pending.insert(shown, at: 0) }
            trimPending()
            present(toast)
            return toast.id
        }
        pending.append(toast)
        trimPending()
        // A confirmation that's been up long enough makes way for what's waiting.
        if autoAdvance, let shown = current, shown.action == nil, !shown.isError {
            scheduleExpiry(of: shown, after: Self.busyDwell)
        }
        return toast.id
    }

    /// Retires one toast whether it is on screen or still waiting; unknown ids are ignored.
    func dismiss(_ id: Toast.ID) {
        if current?.id == id {
            advance()
        } else {
            pending.removeAll { $0.id == id }
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
        announce(toast.message)
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

    /// Oldest confirmation first, then the oldest error; a toast with a button goes last, since
    /// dropping an Undo loses the only visible way back.
    private func trimPending() {
        while pending.count > Self.maxPending {
            if let index = pending.firstIndex(where: { !$0.isError && $0.action == nil }) {
                pending.remove(at: index)
            } else if let index = pending.firstIndex(where: { $0.action == nil }) {
                pending.remove(at: index)
            } else {
                pending.removeFirst()
            }
        }
    }
}
