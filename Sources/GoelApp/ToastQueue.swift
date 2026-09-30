import Foundation
import SwiftUI
import AppKit

/// One transient message at the bottom of the window, optionally with a button (Undo, Retry).
struct Toast: Identifiable, Equatable {
    struct Action {
        let title: String
        let perform: @MainActor () -> Void
    }

    /// What the leading glyph says: done (green check), failed (red octagon), or just so you
    /// know (accent info circle) — a notice that nothing went wrong must not read as success.
    enum Kind: Equatable {
        case success, error, info
    }

    let id = UUID()
    let message: String
    let kind: Kind
    let action: Action?

    var isError: Bool { kind == .error }

    init(message: String, kind: Kind, action: Action?) {
        self.message = message
        self.kind = kind
        self.action = action
    }

    init(message: String, isError: Bool, action: Action?) {
        self.init(message: message, kind: isError ? .error : .success, action: action)
    }

    static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }

    /// Failures linger longer (a missed error is worse than a missed confirmation), and a toast
    /// with a button stays long enough to reach it.
    var dwell: TimeInterval {
        if action != nil { return 8 }
        return isError ? 6 : 2.4
    }
}

/// FIFO, not a single slot: two toasts posted in the same breath both get seen — the second
/// used to overwrite the first before it was ever drawn. Kept apart from the view model so a
/// toast redraws only the overlay that shows it.
@MainActor
final class ToastQueue: ObservableObject {

    @Published private(set) var current: Toast?
    /// Published so the capsule's "+N" chip follows the line behind it.
    @Published private(set) var pending: [Toast] = []
    /// The visible toast's remaining time, for the action toast's shrinking hairline. Nil when
    /// it never expires on its own (VoiceOver keeps action and error toasts up).
    @Published private(set) var countdown: ToastCountdown?

    /// A burst beyond this drops its oldest waiting entries; errors are kept over confirmations,
    /// and toasts with a button over both.
    static let maxPending = 4
    /// With others waiting, a plain confirmation yields after this long instead of its full dwell.
    static let busyDwell: TimeInterval = 1.2

    /// While the pointer rests on it, the visible toast never expires.
    static let releaseGrace: TimeInterval = 2

    private let autoAdvance: Bool
    /// Multiplies every dwell; tests shrink it so timing runs in milliseconds.
    private let timeScale: Double
    private var generation = 0
    private var isHeld = false
    /// When the visible toast is due to leave.
    private var expiresAt: Date?
    /// Unscaled seconds the visible toast had left when the hold began.
    private var heldRemaining: TimeInterval?
    /// Here, not in the overlay: the main window and Settings both draw one, and VoiceOver
    /// heard every toast twice.
    private let announce: @MainActor (String) -> Void
    /// While VoiceOver runs, a toast with a button or an error stays until dismissed or replaced:
    /// reaching it by keyboard takes longer than any dwell.
    private let isVoiceOverRunning: @MainActor () -> Bool

    init(autoAdvance: Bool = true,
         announce: @escaping @MainActor (String) -> Void = { A11yAnnouncer.announce($0) },
         timeScale: Double = 1,
         isVoiceOverRunning: @escaping @MainActor () -> Bool = { NSWorkspace.shared.isVoiceOverEnabled }) {
        self.autoAdvance = autoAdvance
        self.announce = announce
        self.timeScale = timeScale
        self.isVoiceOverRunning = isVoiceOverRunning
    }

    /// Returns the toast's id so its poster can retire it (⌘Z retires an Undo toast); nil when deduplicated.
    @discardableResult
    func show(_ message: String, isError: Bool = false, action: Toast.Action? = nil) -> Toast.ID? {
        show(message, kind: isError ? .error : .success, action: action)
    }

    @discardableResult
    func show(_ message: String, kind: Toast.Kind, action: Toast.Action? = nil) -> Toast.ID? {
        // The same words already on screen or queued add nothing but delay.
        if current?.message == message, current?.kind == kind, action == nil { return nil }
        if pending.contains(where: { $0.message == message && $0.kind == kind && $0.action == nil }),
           action == nil { return nil }
        let toast = Toast(message: message, kind: kind, action: action)
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
        if autoAdvance, !isHeld, let shown = current, shown.action == nil, !shown.isError {
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
        // The held capsule is gone; its replacement is a new view that re-reports hover itself.
        isHeld = false
        heldRemaining = nil
        if pending.isEmpty {
            current = nil
            countdown = nil
        } else {
            present(pending.removeFirst())
        }
    }

    /// Pauses the visible toast's countdown (pointer or focus is on it).
    func hold() {
        guard !isHeld else { return }
        isHeld = true
        heldRemaining = expiresAt.map { max(0, $0.timeIntervalSinceNow) / timeScale }
        // Invalidates the pending expiry.
        generation &+= 1
        if let heldRemaining, let shown = countdown {
            countdown = ToastCountdown(total: shown.total, deadline: nil,
                                       frozenRemaining: heldRemaining * timeScale)
        }
    }

    /// Restarts the countdown with what was left, but never less than ``releaseGrace``.
    func release() {
        guard isHeld else { return }
        isHeld = false
        guard let toast = current else { return }
        let left = heldRemaining ?? toast.dwell
        heldRemaining = nil
        generation &+= 1
        scheduleExpiry(of: toast, after: max(left, Self.releaseGrace))
    }

    /// Runs the button and retires the toast, so a second click can't fire it twice.
    func performAction() {
        guard let action = current?.action else { return }
        advance()
        action.perform()
    }

    private func present(_ toast: Toast) {
        generation &+= 1
        // The held capsule is replaced by a new view that re-reports hover and focus itself; a
        // hold carried over would leave the newcomer with no expiry at all.
        isHeld = false
        heldRemaining = nil
        current = toast
        announce(toast.message)
        let dwell = pending.isEmpty || toast.action != nil || toast.isError ? toast.dwell : Self.busyDwell
        scheduleExpiry(of: toast, after: dwell)
    }

    private func scheduleExpiry(of toast: Toast, after seconds: TimeInterval) {
        let scaled = seconds * timeScale
        let total = max(seconds, toast.dwell) * timeScale
        guard !isHeld else {
            // A toast that arrives under the pointer starts its full time once the pointer leaves.
            heldRemaining = seconds
            countdown = ToastCountdown(total: total, deadline: nil, frozenRemaining: scaled)
            return
        }
        if toast.action != nil || toast.isError, isVoiceOverRunning() {
            expiresAt = nil
            countdown = nil
            return
        }
        expiresAt = Date().addingTimeInterval(scaled)
        countdown = ToastCountdown(total: total, deadline: expiresAt, frozenRemaining: nil)
        guard autoAdvance else { return }
        let expected = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(scaled * 1_000_000_000))
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

/// How much of the visible toast's time is left, as a fraction the hairline draws. While the
/// toast is held (pointer or focus on it) the fraction is frozen at what was left.
struct ToastCountdown: Equatable {
    /// The full span the hairline represents (the toast's dwell, or longer after a release grace).
    let total: TimeInterval
    /// When the toast leaves; nil while held.
    let deadline: Date?
    /// What was left when the hold began; nil while running.
    let frozenRemaining: TimeInterval?

    var isRunning: Bool { deadline != nil }

    func fraction(at now: Date) -> Double {
        guard total > 0 else { return 0 }
        let left = deadline.map { $0.timeIntervalSince(now) } ?? frozenRemaining ?? total
        return min(1, max(0, left / total))
    }
}

extension AppViewModel {
    /// For a notice that is neither a success nor a failure (a feature that is unavailable here).
    @discardableResult
    func toastNow(_ message: String, kind: Toast.Kind, action: Toast.Action? = nil) -> Toast.ID? {
        toasts.show(message, kind: kind, action: action)
    }
}
