import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The floating "drop basket": a small always-on-top panel that accepts link /
/// file drags from any app (browsers especially) and queues them without the
/// main window needing to be visible. Toggled from the View menu.
@MainActor
final class DropBasketController {

    static let shared = DropBasketController()

    private var panel: NSPanel?

    var isVisible: Bool { panel != nil }

    func toggle() {
        if let panel {
            panel.close()
            self.panel = nil
            return
        }
        let content = NSHostingView(rootView: DropBasketView())
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 170, height: 130),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.title = "Drop Basket"
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = content
        panel.center()
        // Park it near the top-right corner, clear of the menu bar.
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 200, y: frame.maxY - 170))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.panel = nil }
        }
    }
}

/// The basket's content: a dashed drop target that forwards dropped links /
/// .torrent files to the shared external-add channel.
private struct DropBasketView: View {
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.to.line.circle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            Text("Drop links here")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                        style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                .padding(8)
        )
        .onDrop(of: [.url, .fileURL, .plainText], isTargeted: $isTargeted) { providers in
            handle(providers)
        }
        .padding(2)
    }

    private func handle(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers {
            if provider.canLoadObject(ofClass: URL.self) {
                accepted = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        // A drop is an explicit user action — queue directly.
                        if var payload = ExternalAdd.payload(from: url) {
                            payload.needsConfirmation = false
                            ExternalAdd.post(payload)
                        }
                    }
                }
            } else if provider.canLoadObject(ofClass: NSString.self) {
                accepted = true
                _ = provider.loadObject(ofClass: NSString.self) { text, _ in
                    guard let text = text as? String, !text.isEmpty else { return }
                    Task { @MainActor in ExternalAdd.post(lines: text) }
                }
            }
        }
        return accepted
    }
}
