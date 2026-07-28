import SwiftUI
import UniformTypeIdentifiers
import GoelCore

struct RootView: View {
    @EnvironmentObject private var vm: AppViewModel

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
                    } else if vm.tasks.isEmpty {
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
            Color(nsColor: .windowBackgroundColor)
                .overlay { if let tint = Theme.windowTint { tint } }
        }
        .overlay(alignment: .bottom) { toastView }
        // Must stay after the toast overlay: a passing toast cannot be allowed to cover the job card.
        .overlay(alignment: .bottomTrailing) { MediaJobDock(center: vm.mediaJobs) }
        .overlay { dropOverlay }
        .overlay { confirmOverlay }
        .onChange(of: vm.toast) { _, message in
            if let message { A11yAnnouncer.announce(message) }
        }
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
                .accessibilityLabel(L10n.t("Warning. %@", warning))
            Spacer()
            Button {
                vm.persistenceWarning = nil
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .a11yButton(L10n.t("Dismiss warning"))
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
            Button {
                vm.dismissClipboardSuggestion()
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .a11yButton(L10n.t("Dismiss copied link suggestion"))
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
