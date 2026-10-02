import SwiftUI
import AppKit
import QuickLook
import GoelCore

/// The Downloads content area that RootView hosts: the content header, then the Board or the
/// List, or the no-match state when the filter and search hide everything. Layout, columns and
/// density are remembered in `@AppStorage`.
struct DownloadListView: View {
    @AppStorage(DownloadsLayout.storageKey) private var layout: DownloadsLayout = .board
    @AppStorage(ListColumnPrefs.storageKey) private var columnsRaw = ""
    @AppStorage(ListDensity.storageKey) private var density: ListDensity = .regular

    var body: some View {
        DownloadsContent(layout: $layout, columnsRaw: $columnsRaw, density: $density)
    }
}

/// The content with its stored preferences passed in, so snapshots can show any layout and
/// density without writing them.
struct DownloadsContent: View {
    @EnvironmentObject private var vm: AppViewModel
    @Binding var layout: DownloadsLayout
    @Binding var columnsRaw: String
    @Binding var density: ListDensity

    @State private var quickLookItem: URL?

    /// Without a default, the window opens with the omnibox as first responder, so ⌘A and the
    /// arrow keys went to an empty text field until the user clicked a row.
    @FocusState private var listFocused: Bool

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 0) {
            DownloadsHeader(layout: $layout, columnsRaw: $columnsRaw, density: $density)
                .padding(.horizontal, Studio.Space.gutter)
                .padding(.top, Studio.Space.l)
                .padding(.bottom, Studio.Space.m)
            if vm.visibleTasks.isEmpty {
                noMatch
            } else if layout == .board {
                DownloadBoardView(inputs: DownloadItemInputs(vm: vm, focused: listFocused))
            } else {
                DownloadTableView(columnsRaw: $columnsRaw, density: $density,
                                  inputs: DownloadItemInputs(vm: vm, focused: listFocused))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Studio.Palette.canvas)
        return content
            .background { keyTarget }
            // A click anywhere in the content hands the keyboard back to the list.
            .simultaneousGesture(TapGesture().onEnded { listFocused = true })
            .defaultFocus($listFocused, true)
            // `defaultFocus` alone is not enough: the queue is restored from disk asynchronously, so
            // this view mounts after the window's first-appearance focus pass has already run.
            .task { listFocused = true }
            // The confirm dialog took the keyboard; give it back once it closes.
            .onChange(of: vm.confirmRequest == nil) { _, closed in if closed { listFocused = true } }
            .quickLookPreview($quickLookItem)
            .environment(\.quickLookAction, QuickLookAction(item: $quickLookItem))
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.t("Download queue"))
            .accessibilityHint(L10n.t("Use the up and down arrow keys to move through downloads, shift with an "
                + "arrow to extend the selection, command A to select all, space to preview, return to open."))
    }

    /// The keyboard target. It sits behind the content rather than wrapping it: a focusable
    /// ancestor makes every button inside read `isFocused` and draw its focus ring.
    private var keyTarget: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress { press in handleKey(press) }
            // Delete removes from the list (undoable); ⌘⌫ (see `handleKey`) is the one that trashes files.
            .onDeleteCommand { if vm.confirmRequest == nil { vm.removeSelected(deleteData: false) } }
            .accessibilityHidden(true)
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // The confirm dialog is modal: nothing reaches the queue behind it.
        guard vm.confirmRequest == nil else { return .ignored }
        let result = handleNavigationKey(press)
        // Only a move speaks: the hidden key target gives VoiceOver nothing to follow.
        if result == .handled, [.upArrow, .downArrow, .leftArrow, .rightArrow, .home, .end].contains(press.key) {
            A11yAnnouncer.announce(vm.keyboardSelectionAnnouncement)
        }
        return result
    }

    private func handleNavigationKey(_ press: KeyPress) -> KeyPress.Result {
        let extending = press.modifiers.contains(.shift)
        switch press.key {
        case .upArrow, .downArrow:
            guard !press.modifiers.contains(.command) else { return .ignored }
            return vm.moveSelection(by: press.key == .downArrow ? 1 : -1, extending: extending, in: layout)
                ? .handled : .ignored
        case .leftArrow, .rightArrow:
            // Across lanes on the board; the list has no columns to move between.
            guard layout == .board, !press.modifiers.contains(.command) else { return .ignored }
            return vm.moveSelectionAcrossLanes(by: press.key == .rightArrow ? 1 : -1, extending: extending)
                ? .handled : .ignored
        case .home, .end:
            return vm.selectEdge(last: press.key == .end, extending: extending, in: layout) ? .handled : .ignored
        case .space:
            guard let task = vm.selectedTask, task.status.hasData else { return .ignored }
            quickLookItem = URL(fileURLWithPath: task.savePath)
            return .handled
        case .return:
            guard let task = vm.selectedTask else { return .ignored }
            vm.openOrReveal(task)
            return .handled
        case .escape:
            guard !vm.selection.isEmpty else { return .ignored }
            vm.selectNone()
            return .handled
        case .delete where press.modifiers.contains(.command):
            // Here, not as a menu key equivalent: only the focused list may claim ⌘⌫.
            guard vm.selectedTasks.contains(where: { $0.status.hasData }) else { return .ignored }
            vm.confirmMoveSelectionToTrash()
            return .handled
        default:
            // The Edit menu owns ⌘A; this is the fallback for when the list, not a text field,
            // holds focus and no menu item claimed the key first. The character is compared
            // case-insensitively because ⇧⌘A arrives as "A".
            guard press.modifiers.contains(.command),
                  press.key.character.lowercased() == "a" else { return .ignored }
            if extending { vm.selectNone() } else { vm.selectAll() }
            return .handled
        }
    }

    private var noMatch: some View {
        DownloadsNoMatch()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, Studio.Space.xxl)
    }
}

/// "No downloads match “x”": says which filter is also hiding things, and clears both at once.
struct DownloadsNoMatch: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        let term = vm.search.trimmingCharacters(in: .whitespacesAndNewlines)
        let narrowed = !vm.filters.isEmpty || !term.isEmpty
        // Echo the search, as the portal does; a filter alone has no words to echo.
        let title = term.isEmpty ? L10n.t("No downloads match") : L10n.t("No downloads match “%@”", term)
        let message = !term.isEmpty && !vm.filters.isEmpty
            ? L10n.t("Try a different filter or search term. The %@ filter is also on.", vm.filters.title)
            : L10n.t("Try a different filter or search term.")
        StudioEmptyState(symbol: "magnifyingglass", title: title, message: message) {
            if narrowed {
                Button(L10n.t("Clear Search and Filter")) {
                    vm.search = ""
                    vm.filters = DownloadFilters()
                }
                .buttonStyle(.studio())
            }
        }
    }
}
