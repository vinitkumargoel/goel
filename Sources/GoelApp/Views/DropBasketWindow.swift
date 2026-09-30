import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GoelCore

@MainActor
final class DropBasketController {

    static let shared = DropBasketController()

    private var panel: NSPanel?

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
        panel.title = L10n.t("Drop Basket")
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = content
        panel.center()
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

private struct DropBasketView: View {
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.to.line.circle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
                .a11yDecorative()
            Text(L10n.t("Drop links here"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .a11yGroup(label: L10n.t("Drop basket"),
                   hint: L10n.t("Drag links or torrent files here to queue them."))
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

    /// URLs go through `InboundDrop` like every other drop target; plain text (a selection dragged
    /// out of a page) has no URL form, so it is parsed as pasted lines.
    private func handle(_ providers: [NSItemProvider]) -> Bool {
        let urlProviders = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        let textProviders = providers.filter {
            !$0.canLoadObject(ofClass: URL.self) && $0.canLoadObject(ofClass: NSString.self)
        }
        var accepted = collectDroppedURLs(urlProviders) { urls in
            // A drop is an explicit user action — queue directly.
            Task { @MainActor in InboundDrop.route(urls, into: AppViewModel.shared) }
        }
        for provider in textProviders {
            if provider.canLoadObject(ofClass: NSString.self) {
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
