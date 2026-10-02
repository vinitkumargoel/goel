import SwiftUI
import UniformTypeIdentifiers
import GoelCore

/// The main window: icon rail, omnibox header, the content (board/list, a server, the RSS reader,
/// or the first-run screen) with the detail sheet floating over it or docked underneath, and the
/// status bar. Hosts the toasts, the media dock, the drop target, the confirm dialog, the
/// auto-shutdown countdown and every sheet the main window presents.
struct RootView: View {
    @EnvironmentObject var vm: AppViewModel
    @Environment(\.undoManager) private var undoManager
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @Environment(\.mainWindowPreview) var preview

    /// Rounded to 10 pt: the dock decision only needs coarse steps, not a redraw per pixel of a resize.
    @State private var windowWidth: CGFloat = 0
    @State var isDropTargeted = false
    @State var isCommandPalettePresented = false
    /// Read once at init: the flag flips when the sheet appears, and re-reading tears it down mid-present.
    @State var isOnboardingPresented = OnboardingState.needsOnboarding
    @State private var flyout: RailFlyout?
    @State private var omniboxText = ""
    @FocusState private var omniboxFocused: Bool

    /// The RSS destination replaces the board, like a server browser does.
    @ObservedObject var rss = RSSReaderModel.shared

    private var forcedBottom: Bool {
        vm.detailPanelPosition == .right
            && WindowLayout.detailPosition(preferred: .right, windowWidth: windowWidth,
                                           sidebarVisible: railExpanded) == .bottom
    }

    var railExpanded: Bool { preview?.railExpanded ?? vm.sidebarVisible }

    /// The open flyout; a snapshot may pin one open.
    private var flyoutBinding: Binding<RailFlyout?> {
        Binding(get: { flyout ?? preview?.flyout }, set: { flyout = $0 })
    }

    /// The first-run screen centres its own omnibox, so the header drops its copy.
    private var showsFirstRun: Bool {
        vm.selectedServer == nil && !rss.isOpen && vm.tasks.isEmpty && !vm.isRestoring
    }

    var body: some View {
        let framed: some View = chrome
            .frame(minWidth: WindowLayout.minimumWindowWidth, minHeight: WindowLayout.minimumWindowHeight)
            .onGeometryChange(for: CGFloat.self) { ($0.size.width / 10).rounded() * 10 } action: { windowWidth = $0 }
            .onChange(of: forcedBottom, initial: true) { _, forced in vm.detailDockForcedBottom = forced }
            .studioWindowBackground()
        return withSheets(withObservers(withOverlays(framed)))
    }

    // Split into typed pieces: one long modifier chain took the older CI toolchain over a
    // second to type-check.

    private var chrome: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                IconRail(isExpanded: railExpanded, flyout: flyoutBinding)
                mainColumn
            }
            .overlay(alignment: .topLeading) { flyoutLayer }
            .animation(panelAnimation, value: railExpanded)
            StatusBar()
        }
    }

    private var mainColumn: some View {
        VStack(spacing: 0) {
            WindowBanners()
            HeaderBar(omniboxText: $omniboxText, omniboxFocus: $omniboxFocused,
                      showsOmnibox: !showsFirstRun)
            MainContentArea(omniboxText: $omniboxText, omniboxFocus: $omniboxFocused)
        }
        .frame(minWidth: WindowLayout.minimumListWidth, maxWidth: .infinity, maxHeight: .infinity)
        // A docked panel wider than a narrow window must not spill over the rail.
        .clipped()
    }

    /// A flyout beside the collapsed rail, over a click-catcher that closes it.
    @ViewBuilder
    private var flyoutLayer: some View {
        if let kind = flyout ?? preview?.flyout, !railExpanded {
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { flyout = nil }
                    .accessibilityHidden(true)
                RailFlyoutPanel(kind: kind) { flyout = nil }
                    .padding(.leading, IconRail.collapsedWidth + Studio.Space.s)
                    .padding(.top, Studio.Space.sm)
                    .padding(.bottom, Studio.Space.l)
                    .transition(reduceMotion ? .opacity : .move(edge: .leading).combined(with: .opacity))
            }
        }
    }

    var panelAnimation: Animation? {
        reduceMotion || preview != nil ? nil : Studio.Motion.spring
    }

    private func withObservers<Content: View>(_ content: Content) -> some View {
        content
            // The window's undo stack is where Edit ▸ Undo looks; "Remove from List" registers there.
            .onAppear {
                vm.undoManager = undoManager
                omniboxText = preview?.omniboxText ?? vm.search
                if preview?.omniboxFocused == true { omniboxFocused = true }
            }
            .onChange(of: undoManager) { _, manager in vm.undoManager = manager }
            .onChange(of: vm.persistenceWarning) { _, warning in
                if let warning { A11yAnnouncer.announce(L10n.t("Warning. %@", warning)) }
            }
            // Typing filters the list; a recognised link filters nothing.
            .onChange(of: omniboxText) { _, text in
                let search = OmniboxInput.classify(text).searchText
                if vm.search != search { vm.search = search }
            }
            // Someone else changed the search ("Clear Search and Filter", the palette).
            .onChange(of: vm.search) { _, search in
                if OmniboxInput.classify(omniboxText).searchText != search { omniboxText = search }
            }
            // SwiftUI ignores `.keyboardShortcut` on a TextField, so ⌘F lives in the menu bar.
            .onReceive(NotificationCenter.default.publisher(for: FocusBus.focusSearch)) { _ in
                flyout = nil
                omniboxFocused = true
            }
            // History and the player are windows now; the flags stay as the one way to ask for them.
            .onChange(of: vm.isHistoryPresented) { _, wanted in
                guard wanted else { return }
                openWindow(id: MainWindowID.history)
                vm.isHistoryPresented = false
            }
            .onChange(of: vm.playerItem?.id) { _, id in
                if id != nil { openWindow(id: MainWindowID.player) }
            }
            .animation(.easeInOut(duration: 0.08), value: isDropTargeted)
            .onDrop(of: [.url, .fileURL], isTargeted: $isDropTargeted) { handleDrop($0) }
            .onReceive(NotificationCenter.default.publisher(for: CommandPaletteBus.toggleNotification)) { _ in
                // Suppressed during onboarding, or the first-run sheet ends up underneath a second sheet.
                guard !isOnboardingPresented else { return }
                flyout = nil
                isCommandPalettePresented.toggle()
            }
            .onReceive(NotificationCenter.default.publisher(for: OnboardingState.showAgainNotification)) { _ in
                guard preview == nil else { return }
                // After the palette (which may have run this command) has finished dismissing.
                let wasPalette = isCommandPalettePresented
                isCommandPalettePresented = false
                Task { @MainActor in
                    if wasPalette { try? await Task.sleep(for: .milliseconds(350)) }
                    isOnboardingPresented = true
                }
            }
            // A crash or force-quit mid-preview leaves SFTP Quick Look copies in $TMPDIR.
            .task(priority: .background) {
                guard preview == nil else { return }
                QuickLookPresenter.sweepStaleTemps()
            }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        collectDroppedURLs(providers) { urls in
            Task { @MainActor in InboundDrop.route(urls, into: vm) }
        }
    }
}
