import AppKit

/// Watches the system pasteboard and reports newly-copied text so the app can
/// offer to download a copied http(s)/magnet link.
///
/// It polls `NSPasteboard.changeCount` (there is no change notification on
/// macOS) on a light 1.2s timer. The baseline is seeded at init, so whatever is
/// already on the clipboard at launch never triggers a suggestion — only copies
/// made while the app runs do. Action is gated on ``isEnabled`` so the timer can
/// keep running cheaply while the feature is toggled off.
@MainActor
final class ClipboardMonitor {
    /// Whether copies should be reported. Synced from the user setting.
    var isEnabled: Bool

    private let onText: (String) -> Void
    private var timer: Timer?
    private var lastChangeCount: Int

    init(isEnabled: Bool, onText: @escaping (String) -> Void) {
        self.isEnabled = isEnabled
        self.onText = onText
        self.lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        guard timer == nil else { return }
        // Build unscheduled and add in `.common` so it keeps firing while menus or
        // sheets track the run loop (scheduledTimer would only register `.default`).
        let timer = Timer(timeInterval: 1.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        guard isEnabled else { return }   // still consume the change so it isn't re-fired later
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        onText(text)
    }
}
