import AppKit

@MainActor
final class ClipboardMonitor {
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
        // Added in `.common` so it keeps firing while menus or sheets track the run loop; scheduledTimer registers only `.default`.
        let timer = Timer(timeInterval: 1.2, repeats: true) { [weak self] _ in
            // Bound here rather than `self?.` inside the Task: a capture list makes `self` a var, which older toolchains refuse to read from concurrent code.
            guard let self else { return }
            Task { @MainActor in self.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
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
