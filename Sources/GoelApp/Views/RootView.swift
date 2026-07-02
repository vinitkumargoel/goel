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

    /// The detail panel is shown only when it's toggled on *and* a download is
    /// actually selected — so clicking away (deselecting) makes it slide out, and
    /// it returns when a task is picked again.
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
                // The list — with the detail panel docked *below* it when the user
                // has chosen the bottom position. `maxWidth: .infinity` makes this
                // the greedy pane so the fixed-width right panel always keeps its
                // 340pt (and never gets pushed off the window edge).
                VStack(spacing: 0) {
                    if let server = vm.server(vm.selectedServer) {
                        // A server is selected — browse it instead of the list.
                        // Keyed by id so switching servers rebuilds the browser.
                        SFTPBrowserView(connection: server,
                                        client: vm.sftpClient(for: server))
                            .id(server.id)
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
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) { toastView }
        .overlay { dropOverlay }
        .overlay { confirmOverlay }
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
    }

    /// The dashed "drop here" affordance shown only while a drag hovers the window
    /// (the brief's "visible drop target"). Hit-testing is disabled so the drag
    /// keeps reaching the underlying `.onDrop` region.
    @ViewBuilder
    private var dropOverlay: some View {
        if isDropTargeted {
            ZStack {
                Color.black.opacity(0.10).ignoresSafeArea()
                VStack(spacing: 14) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 34, weight: .regular))
                    Text("Drop a URL or .torrent file here")
                        .font(.system(size: 15, weight: .semibold))
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

    /// Collect every web/file URL the drag carries and hand the newline-joined
    /// locators to the manager. `.torrent` file URLs and http(s)/magnet links are
    /// validated downstream by `DownloadSource.parse`; anything else is dropped.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let urlProviders = providers.filter { $0.canLoadObject(ofClass: URL.self) }
        guard !urlProviders.isEmpty else { return false }
        let group = DispatchGroup()
        let lock = NSLock()
        var locators: [String] = []
        for provider in urlProviders {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock(); locators.append(url.absoluteString); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            guard !locators.isEmpty else { return }
            let raw = locators.joined(separator: "\n")
            Task { @MainActor in
                vm.add(rawLines: raw, saveDirectory: nil, priority: .normal)
            }
        }
        return true
    }

    private func persistenceBanner(_ warning: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.orange)
            Text(warning).font(.system(size: 12))
            Spacer()
            Button {
                vm.persistenceWarning = nil
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
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
            Text("Copied link detected").font(.system(size: 12, weight: .semibold))
            Text(link)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Add") { vm.acceptClipboardSuggestion() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button {
                vm.dismissClipboardSuggestion()
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
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
                Text(toast).font(.system(size: 12.5))
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Theme.hairline))
            .shadow(radius: 12, y: 6)
            .padding(.bottom, 52)
            .transition(.opacity)
        }
    }
}
