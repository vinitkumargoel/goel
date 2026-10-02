import SwiftUI
import AppKit
import UniformTypeIdentifiers
import GoelCore

/// The Drop Basket: a small always-on-top panel that takes links, .torrent files and text with
/// links from anywhere, without bringing the main window forward.
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
        let size = NSSize(width: DropBasketView.width, height: DropBasketView.height)
        let content = NSHostingView(rootView: DropBasketView(vm: AppViewModel.shared))
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.title = L10n.t("Drop Basket")
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = content
        panel.applyStudioChrome()
        panel.backgroundColor = Studio.Tones.sheet.nsColor
        panel.center()
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - size.width - 30, y: frame.maxY - size.height - 40))
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

/// The basket's content: the drop target, "✓ n added" after a drop, and the newest downloads.
struct DropBasketView: View {
    static let width: CGFloat = 300
    static let height: CGFloat = 268

    let vm: AppViewModel?
    @State private var isTargeted: Bool
    /// "✓ 3 added" after a drop, until the next one or a few seconds pass.
    @State private var addedCount: Int?
    @State private var feedbackTask: Task<Void, Never>?

    /// `addedCount` and `isTargeted` are for previews and snapshots.
    init(vm: AppViewModel?, addedCount: Int? = nil, isTargeted: Bool = false) {
        self.vm = vm
        _addedCount = State(initialValue: addedCount)
        _isTargeted = State(initialValue: isTargeted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.sm) {
            dropTarget
            if let addedCount {
                Label(L10n.t("%d added", addedCount), systemImage: "checkmark")
                    .labelStyle(StudioButtonLabelStyle())
                    .studioFont(.small.weight(650))
                    .foregroundStyle(Studio.Palette.good)
                    .transition(.opacity)
                    .accessibilityHidden(true)
            }
            if let vm { DropBasketRecent(vm: vm) }
        }
        .padding(Studio.Space.ml)
        .frame(width: Self.width, height: Self.height, alignment: .top)
        .background(Studio.Palette.sheet)
        .animation(Studio.Motion.quick, value: addedCount)
    }

    private var dropTarget: some View {
        WindowsDropZone(isTargeted: isTargeted, minHeight: 96) {
            Image(systemName: isTargeted ? "arrow.down.circle.fill" : "arrow.down.to.line")
                .studioFont(.ui, size: 20, weight: 650)
                .accessibilityHidden(true)
            Text(L10n.t("Drop links here"))
                .studioFont(.small.weight(700))
            Text(L10n.t("URLs, .torrent files, text with links"))
                .studioFont(.tiny)
                .foregroundStyle(Studio.Palette.ink3)
        }
        .frame(maxHeight: .infinity)
        .a11yGroup(label: L10n.t("Drop basket"),
                   value: addedCount.map { L10n.t("%d added", $0) },
                   hint: L10n.t("Drag links or torrent files here to queue them."))
        .onDrop(of: [.url, .fileURL, .plainText], isTargeted: $isTargeted) { providers in
            handle(providers)
        }
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
        for provider in textProviders where provider.canLoadObject(ofClass: NSString.self) {
            accepted = true
            _ = provider.loadObject(ofClass: NSString.self) { text, _ in
                guard let text = text as? String, !text.isEmpty else { return }
                Task { @MainActor in
                    ExternalAdd.post(lines: text)
                    showAdded(InboundAdd.parseSources(from: text).count)
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

/// The three most recently added downloads, each with a thin bar, so a drop visibly lands.
private struct DropBasketRecent: View {
    @ObservedObject var vm: AppViewModel

    private var recent: [DownloadTask] {
        Array(vm.tasks.sorted { $0.addedAt > $1.addedAt }.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.xs) {
            ForEach(recent) { task in
                let done = task.status == .completed
                HStack(spacing: Studio.Space.s) {
                    StudioFileArtwork(kind: StudioArtKind(task: task), size: .xs)
                    FileNameText(task.name, lineLimit: 1)
                        .studioFont(.small)
                        .foregroundStyle(Studio.Palette.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if done {
                        Image(systemName: "checkmark")
                            .studioFont(.ui, size: 10, weight: 750)
                            .foregroundStyle(Studio.Palette.good)
                            .accessibilityHidden(true)
                    } else {
                        StudioLinearProgress(fraction: task.fractionCompleted,
                                             tone: task.status == .paused ? .paused : .accent,
                                             height: StudioLinearProgress.thinHeight)
                            .frame(width: 50)
                    }
                }
                .a11yGroup(label: task.name,
                           value: L10n.t("%d percent", Int((task.fractionCompleted * 100).rounded(.down))))
            }
        }
    }
}
