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
        let content = NSHostingView(rootView: DropBasketView(vm: AppViewModel.shared))
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 210),
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
            panel.setFrameOrigin(NSPoint(x: frame.maxX - 250, y: frame.maxY - 250))
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
    let vm: AppViewModel?
    @State private var isTargeted = false
    /// "✓ 3 added" after a drop, until the next one or a few seconds pass.
    @State private var addedCount: Int?
    @State private var feedbackTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 6) {
            dropTarget
            if let vm { DropBasketRecent(vm: vm) }
        }
        .padding(.bottom, 6)
    }

    private var dropTarget: some View {
        VStack(spacing: 8) {
            Image(systemName: addedCount == nil ? "arrow.down.to.line.circle" : "checkmark.circle.fill")
                .scaledFont(size: 26, weight: .light)
                .foregroundStyle(addedCount != nil ? Theme.green : (isTargeted ? Color.accentColor : .secondary))
                .a11yDecorative()
            Text(addedCount.map { L10n.t("✓ %d added", $0) } ?? L10n.t("Drop links here"))
                .scaledFont(size: Theme.TextSize.meta, weight: addedCount == nil ? .regular : .semibold)
                .foregroundStyle(addedCount == nil ? Color.secondary : Theme.green)
        }
        .a11yGroup(label: L10n.t("Drop basket"),
                   value: addedCount.map { L10n.t("%d added", $0) },
                   hint: L10n.t("Drag links or torrent files here to queue them."))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.card)
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
            Task { @MainActor in
                InboundDrop.route(urls, into: AppViewModel.shared)
                let plan = InboundDrop.plan(for: urls)
                showAdded(plan.links.count + plan.torrentFiles.count)
            }
        }
        for provider in textProviders {
            if provider.canLoadObject(ofClass: NSString.self) {
                accepted = true
                _ = provider.loadObject(ofClass: NSString.self) { text, _ in
                    guard let text = text as? String, !text.isEmpty else { return }
                    Task { @MainActor in
                        ExternalAdd.post(lines: text)
                        showAdded(InboundAdd.parseSources(from: text).count)
                    }
                }
            }
        }
        return accepted
    }

    private func showAdded(_ count: Int) {
        guard count > 0 else { return }
        addedCount = count
        feedbackTask?.cancel()
        feedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { addedCount = nil }
        }
    }
}

/// The three most recently added downloads, with a thin bar each, so a drop visibly lands.
private struct DropBasketRecent: View {
    @ObservedObject var vm: AppViewModel

    private var recent: [DownloadTask] {
        Array(vm.tasks.sorted { $0.addedAt > $1.addedAt }.prefix(3))
    }

    var body: some View {
        VStack(spacing: 4) {
            ForEach(recent) { task in
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.name)
                        .scaledFont(size: Theme.TextSize.micro)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    ProgressView(value: task.status == .completed ? 1 : task.fractionCompleted)
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                        .tint(task.status == .completed ? Theme.green : Theme.accent)
                }
                .a11yGroup(label: task.name,
                           value: L10n.t("%d percent", Int((task.fractionCompleted * 100).rounded(.down))))
            }
        }
        .padding(.horizontal, 12)
    }
}
