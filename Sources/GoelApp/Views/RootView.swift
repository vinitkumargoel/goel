import SwiftUI
import UniformTypeIdentifiers
import GoelCore

struct RootView: View {
    @EnvironmentObject private var vm: AppViewModel
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The bottom detail panel's height, dragged by its top edge.
    @AppStorage("detailBottomPanelHeight") private var bottomPanelHeight: Double = DetailPanelHeight.standard
    /// The height when the current drag began; nil between drags.
    @State private var dragStartHeight: Double?

    @State private var isDropTargeted = false

    @State private var isCommandPalettePresented = false

    /// Read once at init: the flag flips when the sheet appears, and re-reading tears it down mid-present.
    @State private var isOnboardingPresented = OnboardingState.needsOnboarding

    private var showDetail: Bool {
        vm.detailPanelVisible && vm.selectedTask != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            AppToolbar()
            Divider()
            if let warning = vm.persistenceWarning {
                persistenceBanner(warning)
                Divider()
            }
            if let warning = vm.serverStoreWarning {
                warningBanner(warning) { vm.serverStoreWarning = nil }
                Divider()
            }
            if let link = vm.clipboardSuggestion {
                clipboardBanner(link)
                Divider()
            }
            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: 200)
                Divider()
                VStack(spacing: 0) {
                    if let server = vm.server(vm.selectedServer) {
                        // The `.id` must include the generation, or Reconnect reuses the dead client.
                        SFTPBrowserView(connection: server,
                                        client: vm.sftpClient(for: server))
                            .id("\(server.id)-\(vm.browserGeneration)")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if vm.tasks.isEmpty && vm.isRestoring {
                        // The queue loads asynchronously; the first-run screen would flash here.
                        RestoringPlaceholderList()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if vm.tasks.isEmpty {
                        DownloadsEmptyState()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        DownloadListView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if showDetail && vm.detailPanelPosition == .bottom {
                            bottomPanelHandle
                            DetailBottomPanel()
                                .frame(height: DetailPanelHeight.clamped(bottomPanelHeight))
                                .transition(panelTransition(.bottom))
                        }
                    }
                }
                .frame(minWidth: 420, maxWidth: .infinity)
                if showDetail && vm.selectedServer == nil && vm.detailPanelPosition == .right {
                    Divider()
                    DetailPanelView()
                        .frame(width: 340)
                        .transition(panelTransition(.trailing))
                }
            }
            .animation(panelAnimation, value: vm.detailPanelVisible)
            .animation(panelAnimation, value: vm.detailPanelPosition)
            .animation(panelAnimation, value: showDetail)
            Divider()
            StatusBarView()
        }
        .frame(minWidth: 1040, minHeight: 620)
        .background {
            Color(nsColor: .windowBackgroundColor)
                .overlay { if let tint = Theme.windowTint { tint } }
        }
        .overlay(alignment: .bottom) { ToastOverlay(queue: vm.toasts) }
        // Must stay after the toast overlay: a passing toast cannot be allowed to cover the job card.
        .overlay(alignment: .bottomTrailing) { MediaJobDock(center: vm.mediaJobs) }
        .overlay { dropOverlay }
        .overlay { confirmOverlay }
        .overlay { AutoShutdownCountdownView(countdown: vm.autoShutdownCountdown) }
        // The window's undo stack is where Edit ▸ Undo looks; "Remove from List" registers there.
        .onAppear { vm.undoManager = undoManager }
        .onChange(of: undoManager) { _, manager in vm.undoManager = manager }
        .onChange(of: vm.persistenceWarning) { _, warning in
            if let warning { A11yAnnouncer.announce(L10n.t("Warning. %@", warning)) }
        }
        .animation(.easeInOut(duration: 0.08), value: isDropTargeted)
        .onDrop(of: [.url, .fileURL], isTargeted: $isDropTargeted) { handleDrop($0) }
        .sheet(isPresented: $vm.isAddSheetPresented) {
            AddDownloadSheet()
                .environmentObject(vm)
        }
        .sheet(isPresented: $vm.isStatsPresented) {
            StatsView()
                .environmentObject(vm)
        }
        .sheet(isPresented: $vm.isHistoryPresented) {
            HistoryView()
                .environmentObject(vm)
        }
        .sheet(isPresented: $vm.isLinkGrabberPresented) {
            LinkGrabberSheet()
                .environmentObject(vm)
        }
        .sheet(isPresented: $vm.isServerEditorPresented) {
            SFTPConnectionEditor(existing: vm.editingServer)
                .environmentObject(vm)
        }
        .sheet(item: $vm.sftpUploadConflicts) { request in
            SFTPUploadConflictSheet(
                request: request,
                onResolve: { vm.resolveUploadConflicts(request, decisions: $0) },
                onCancel: { vm.sftpUploadConflicts = nil })
        }
        .sheet(item: $vm.playerItem) { item in
            InAppPlayerView(item: item) { vm.playerItem = nil }
        }
        .sheet(isPresented: $isCommandPalettePresented) {
            CommandPalette()
                .environmentObject(vm)
        }
        .sheet(isPresented: $isOnboardingPresented) {
            OnboardingView()
                .environmentObject(vm)
        }
        .onReceive(NotificationCenter.default.publisher(for: CommandPaletteBus.toggleNotification)) { _ in
            // Suppressed during onboarding, or the first-run sheet ends up underneath a second sheet.
            guard !isOnboardingPresented else { return }
            isCommandPalettePresented.toggle()
        }
        // A crash or force-quit mid-preview leaves SFTP Quick Look copies in $TMPDIR.
        .task(priority: .background) { QuickLookPresenter.sweepStaleTemps() }
    }

    /// Under Reduce Motion panels fade in place instead of sliding.
    private func panelTransition(_ edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    private var panelAnimation: Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.14)
    }

    /// The divider above the bottom panel doubles as its resize grip.
    private var bottomPanelHandle: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(height: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStartHeight ?? DetailPanelHeight.clamped(bottomPanelHeight)
                                dragStartHeight = start
                                // Dragging up makes the panel taller.
                                bottomPanelHeight = DetailPanelHeight.clamped(start - value.translation.height)
                            }
                            .onEnded { _ in dragStartHeight = nil }
                    )
                    .accessibilityElement()
                    .accessibilityLabel(L10n.t("Detail panel height"))
                    .accessibilityValue(L10n.t("%d points", Int(DetailPanelHeight.clamped(bottomPanelHeight))))
                    .accessibilityAdjustableAction { direction in
                        let step = direction == .increment ? DetailPanelHeight.step : -DetailPanelHeight.step
                        bottomPanelHeight = DetailPanelHeight.clamped(bottomPanelHeight + step)
                    }
                    .help(L10n.t("Drag to resize the detail panel"))
            }
    }

    /// Hit-testing stays disabled here, or this overlay swallows the drag before `.onDrop` sees it.
    @ViewBuilder
    private var dropOverlay: some View {
        if isDropTargeted {
            ZStack {
                Color.black.opacity(0.10).ignoresSafeArea()
                VStack(spacing: 14) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 34, weight: .regular))
                    Text(L10n.t("Drop a URL or .torrent file here"))
                        .scaledFont(size: 15, weight: .semibold)
                }
                .foregroundStyle(Theme.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [9, 6]))
                )
                .padding(26)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
            .a11yDecorative()
        }
    }

    @ViewBuilder
    private var confirmOverlay: some View {
        if let request = vm.confirmRequest {
            ConfirmDialogView(request: request) { vm.confirmRequest = nil }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        collectDroppedURLs(providers) { urls in
            Task { @MainActor in InboundDrop.route(urls, into: vm) }
        }
    }

    private func persistenceBanner(_ warning: String) -> some View {
        // Not dismissible while nothing is being saved: the user must not forget that.
        warningBanner(warning, dismiss: vm.isStoreEphemeral ? nil : { vm.persistenceWarning = nil })
    }

    private func warningBanner(_ warning: String, dismiss: (() -> Void)?) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange)
                .a11yDecorative()
            Text(warning).scaledFont(size: 12)
                .accessibilityLabel(L10n.t("Warning. %@", warning))
            Spacer()
            if vm.databaseRecovery != nil, warning == vm.persistenceWarning {
                Button(L10n.t("Move the Broken Database Aside…")) { confirmDatabaseRecovery() }
                    .controlSize(.small)
            }
            if let dismiss {
                IconButton(symbol: "xmark", help: L10n.t("Dismiss warning"), size: 10, action: dismiss)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Theme.orange.opacity(0.12))
    }

    private func clipboardBanner(_ link: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard.fill").foregroundStyle(Theme.accent)
                .a11yDecorative()
            Text(L10n.t("Copied link detected")).scaledFont(size: 12, weight: .semibold)
            Text(link)
                .scaledFont(size: 11, design: .monospaced)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(L10n.t("Add")) { vm.acceptClipboardSuggestion() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityLabel(L10n.t("Add copied link to downloads"))
            IconButton(symbol: "xmark", help: L10n.t("Dismiss copied link suggestion"), size: 10) {
                vm.dismissClipboardSuggestion()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Theme.accent.opacity(0.10))
    }

    private func confirmDatabaseRecovery() {
        guard let recovery = vm.databaseRecovery else { return }
        vm.requestConfirm(
            title: L10n.t("Move the broken database aside and start fresh?"),
            message: L10n.t("Goel° couldn’t open %1$@ (%2$@). It will be renamed, not deleted, so nothing is lost; the next launch starts with an empty list.",
                            (recovery.path as NSString).lastPathComponent, recovery.reason),
            confirmTitle: L10n.t("Move Aside")
        ) { vm.moveBrokenDatabaseAside() }
    }
}

/// Where the bottom detail panel's height may go, in points.
enum DetailPanelHeight {
    static let standard: Double = 300
    static let range: ClosedRange<Double> = 220...480
    /// One VoiceOver increment.
    static let step: Double = 20

    static func clamped(_ height: Double) -> Double {
        guard height.isFinite else { return standard }
        return min(max(height, range.lowerBound), range.upperBound)
    }
}

/// Grey bars in the shape of the queue while it restores from disk.
private struct RestoringPlaceholderList: View {
    private static let names = ["ubuntu-24.04.1-desktop-amd64.iso", "project-backup.tar.zst",
                                "Cosmos.S01E04.2160p.mkv", "imagenet-mini-dataset.zip"]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(Self.names.enumerated()), id: \.offset) { _, name in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: Theme.Radius.control)
                        .frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(name).scaledFont(size: 12.5, weight: .medium)
                        Text("62% · 3m left").scaledFont(size: Theme.TextSize.meta)
                    }
                    Spacer()
                    Text("4.7 GB").scaledFont(size: Theme.TextSize.meta)
                }
                .padding(.horizontal, 24)
                .frame(minHeight: 50)
                Divider()
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 29)
        .redacted(reason: .placeholder)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.t("Loading downloads"))
    }
}
