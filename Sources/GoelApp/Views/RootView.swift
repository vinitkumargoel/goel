import SwiftUI
import UniformTypeIdentifiers
import GoelCore

/// The whole window: a top toolbar, a sidebar | list | detail body, and a bottom
/// status bar — matching the layout in `visual.html`.
struct RootView: View {
    @EnvironmentObject private var vm: AppViewModel

    /// Highlights the window-wide drop target while a web URL or `.torrent` file
    /// is dragged over the window. Drops are routed straight into the add flow.
    @State private var isDropTargeted = false

    /// The ⌘K palette, raised either by the View menu command (via ``CommandPaletteBus``, since a
    /// `Commands` body can't reach this state) or by the empty state's shortcut row.
    @State private var isCommandPalettePresented = false

    /// The first-run flow, evaluated once at init rather than on every update: the flag flips as soon
    /// as the sheet appears, and re-reading it would tear the sheet down mid-presentation.
    @State private var isOnboardingPresented = OnboardingState.needsOnboarding

    /// The detail panel shows only when toggled on *and* a download is selected — so deselecting
    /// slides it out, and it returns when a task is picked again.
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
            if let link = vm.clipboardSuggestion {
                clipboardBanner(link)
                Divider()
            }
            HStack(spacing: 0) {
                SidebarView()
                    .frame(width: 200)
                Divider()
                // The list, with the detail panel docked below it under the bottom position. `maxWidth: .infinity`
                // makes this the greedy pane so the fixed-width right panel always keeps its 340pt.
                VStack(spacing: 0) {
                    if let server = vm.server(vm.selectedServer) {
                        // A server is selected — browse it instead of the list. Keyed by id so switching servers rebuilds
                        // the browser, and by generation so Reconnect rebuilds against a fresh client.
                        SFTPBrowserView(connection: server,
                                        client: vm.sftpClient(for: server))
                            .id("\(server.id)-\(vm.browserGeneration)")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if vm.tasks.isEmpty {
                        // A genuinely empty queue, as opposed to a filter matching nothing (which `DownloadListView`
                        // owns). This is a new user's first screen, so it offers the ways in.
                        DownloadsEmptyState()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        DownloadListView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        if showDetail && vm.detailPanelPosition == .bottom {
                            Divider()
                            DetailBottomPanel()
                                .frame(height: 300)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                    }
                }
                .frame(minWidth: 420, maxWidth: .infinity)
                // …or docked on the right edge (the default).
                if showDetail && vm.selectedServer == nil && vm.detailPanelPosition == .right {
                    Divider()
                    DetailPanelView()
                        .frame(width: 340)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.14), value: vm.detailPanelVisible)
            .animation(.easeInOut(duration: 0.14), value: vm.detailPanelPosition)
            .animation(.easeInOut(duration: 0.14), value: showDetail)
            Divider()
            StatusBarView()
        }
        .frame(minWidth: 1040, minHeight: 620)
        .background {
            // System canvas plus an optional theme wash, so themes with a non-neutral background read as
            // that colour under the translucent chrome. Frost themes leave it untinted.
            Color(nsColor: .windowBackgroundColor)
                .overlay { if let tint = Theme.windowTint { tint } }
        }
        .overlay(alignment: .bottom) { toastView }
        // Above the toast layer: a conversion card persists for the whole job,
        // and a passing toast must not be able to sit on top of it.
        .overlay(alignment: .bottomTrailing) { MediaJobDock(center: vm.mediaJobs) }
        .overlay { dropOverlay }
        .overlay { confirmOverlay }
        // Toasts and the persistence banner are the app's only feedback for several actions and never
        // take focus, so without an explicit announcement a screen-reader user gets no confirmation.
        .onChange(of: vm.toast) { _, message in
            if let message { A11yAnnouncer.announce(message) }
        }
        .onChange(of: vm.persistenceWarning) { _, warning in
            if let warning { A11yAnnouncer.announce("Warning. \(warning)") }
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
        // First run only. `OnboardingView` writes the completion flag itself on
        // every exit path, so this presents at most once per install.
        .sheet(isPresented: $isOnboardingPresented) {
            OnboardingView()
                .environmentObject(vm)
        }
        .onReceive(NotificationCenter.default.publisher(for: CommandPaletteBus.toggleNotification)) { _ in
            // A second ⌘K while it's open closes it, the way every other palette behaves. Suppressed during
            // onboarding so the first-run flow can't end up underneath a second sheet.
            guard !isOnboardingPresented else { return }
            isCommandPalettePresented.toggle()
        }
    }

    /// The dashed "drop here" affordance shown only while a drag hovers the window. Hit-testing is
    /// disabled so the drag keeps reaching the underlying `.onDrop` region.
    @ViewBuilder
    private var dropOverlay: some View {
        if isDropTargeted {
            ZStack {
                Color.black.opacity(0.10).ignoresSafeArea()
                VStack(spacing: 14) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 34, weight: .regular))
                    Text("Drop a URL or .torrent file here")
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
            // Purely a drag affordance: it exists only while a pointer drag is
            // in flight, which is not a state reachable without a pointer.
            .a11yDecorative()
        }
    }

    /// The app's own confirmation dialog, shown whenever a call site raises a
    /// ``AppViewModel/ConfirmRequest`` (replaces the system `.confirmationDialog`).
    @ViewBuilder
    private var confirmOverlay: some View {
        if let request = vm.confirmRequest {
            ConfirmDialogView(request: request) { vm.confirmRequest = nil }
        }
    }

    /// Collect every web/file URL the drag carries and hand the newline-joined locators to the
    /// manager. Validation happens downstream in `DownloadSource.parse`; anything else is dropped.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        collectDroppedURLs(providers) { urls in
            guard !urls.isEmpty else { return }
            let raw = urls.map(\.absoluteString).joined(separator: "\n")
            Task { @MainActor in
                vm.add(rawLines: raw, saveDirectory: nil, priority: .normal)
            }
        }
    }

    private func persistenceBanner(_ warning: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange)
                .a11yDecorative()
            Text(warning).scaledFont(size: 12)
                // The triangle and the orange wash are what mark this as a
                // warning rather than a notice — neither survives to the ear.
                .accessibilityLabel("Warning. \(warning)")
            Spacer()
            Button {
                vm.persistenceWarning = nil
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .a11yButton("Dismiss warning")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Theme.orange.opacity(0.12))
    }

    /// An actionable banner offering to download a link just copied to the
    /// clipboard (shown only while clipboard capture is enabled).
    private func clipboardBanner(_ link: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard.fill").foregroundStyle(Theme.accent)
                .a11yDecorative()
            Text("Copied link detected").scaledFont(size: 12, weight: .semibold)
            Text(link)
                .scaledFont(size: 11, design: .monospaced)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Add") { vm.acceptClipboardSuggestion() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                // Bare "Add" doesn't say what gets added.
                .accessibilityLabel("Add copied link to downloads")
            Button {
                vm.dismissClipboardSuggestion()
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .a11yButton("Dismiss copied link suggestion")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Theme.accent.opacity(0.10))
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast = vm.toast {
            HStack(spacing: 9) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                    .a11yDecorative()
                Text(toast).scaledFont(size: 12.5)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Theme.hairline))
            .shadow(radius: 12, y: 6)
            .padding(.bottom, 52)
            .transition(.opacity)
            .a11yGroup(label: toast)
        }
    }
}
