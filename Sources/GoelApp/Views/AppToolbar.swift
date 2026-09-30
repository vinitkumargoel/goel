import SwiftUI
import GoelCore

struct AppToolbar: View {
    @EnvironmentObject private var vm: AppViewModel

    /// Driven by `FocusBus`: SwiftUI ignores `.keyboardShortcut` on a TextField, so ⌘F lives
    /// in the menu bar and reaches the field through a notification.
    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button {
                vm.sidebarVisible.toggle()
            } label: {
                Image(systemName: "sidebar.left")
            }
            .buttonStyle(.borderless)
            .controlSize(.large)
            // ⌃⌘S is bound once, in View ▸ Toggle Sidebar.
            .help(ShortcutHint.help(L10n.t("Toggle sidebar"), "⌃⌘S"))
            .a11yButton(L10n.t("Sidebar"))
            .accessibilityValue(vm.sidebarVisible ? L10n.t("Shown") : L10n.t("Hidden"))

            Button {
                vm.isAddSheetPresented = true
            } label: {
                Label(L10n.t("Add download"), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            // ⌘N lives in File ▸ Add Download…; binding it here too made the shortcut ambiguous.
            .help(ShortcutHint.help(L10n.t("Add download"), "⌘N"))

            Divider().frame(height: 20)

            ActionMenu(items: [
                .button(L10n.t("Select all")) { vm.selectAll() },
                .button(L10n.t("Select none")) { vm.selectNone() },
                .button(L10n.t("Select completed")) { vm.selectCompleted() },
                ActionMenuItem(kind: .separator),
                // Off the list, not off the disk; the toast that follows offers Undo.
                .button(L10n.t("Clear completed")) { vm.clearCompleted() },
            ]) { open in
                ToolbarMenuLabel(title: L10n.t("Select"), systemImage: "checkmark.circle", active: open)
            }
            .accessibilityValue(L10n.t("%d selected", vm.selection.count))

            ActionMenu(items: sortItems) { open in
                ToolbarMenuLabel(title: L10n.t("Sort"), systemImage: "arrow.up.arrow.down", active: open)
            }
            .accessibilityValue(L10n.t("%1$@, %2$@", vm.sortKey.title,
                                      vm.sortAscending ? L10n.t("ascending") : L10n.t("descending")))

            filterControl

            Spacer()

            pauseResumeAllButton

            searchField

            Button {
                vm.detailPanelVisible.toggle()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            // ⌘I is bound once, in View ▸ Toggle Detail Panel; the palette advertises the same key.
            .help(ShortcutHint.help(L10n.t("Toggle detail panel"), "⌘I"))
            .tint(vm.detailPanelVisible ? Theme.accent : nil)
            .a11yButton(L10n.t("Detail panel"))
            .accessibilityValue(vm.detailPanelVisible ? L10n.t("Shown") : L10n.t("Hidden"))
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(.bar)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .scaledFont(size: Theme.TextSize.body)
                .a11yDecorative()
            TextField(L10n.t("Search downloads"), text: $vm.search)
                .textFieldStyle(.plain)
                .scaledFont(size: Theme.TextSize.body)
                // Gives way first when the window narrows, so the menus keep their labels.
                .frame(minWidth: 90, idealWidth: 180, maxWidth: 180)
                .accessibilityLabel(L10n.t("Search downloads"))
                .focused($searchFocused)
                .help(ShortcutHint.help(L10n.t("Search downloads (host:example.com narrows to a site)"), "⌘F"))
                .onExitCommand {
                    // Escape clears, then a second Escape hands the keyboard back to the list.
                    if vm.search.isEmpty { searchFocused = false } else { vm.search = "" }
                }
            if !vm.search.isEmpty {
                IconButton(symbol: "xmark.circle.fill", help: L10n.t("Clear search"), size: 11) {
                    vm.search = ""
                    // Back to the field, so the next search can be typed straight away.
                    searchFocused = true
                }
            }
            PaletteKeycap()
        }
        .onReceive(NotificationCenter.default.publisher(for: FocusBus.focusSearch)) { _ in
            searchFocused = true
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 28)
        .background(Theme.fillRest, in: RoundedRectangle(cornerRadius: Theme.Radius.field))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.field).stroke(Theme.hairline))
    }

    /// The sort keys, then Group by: both decide how the list is laid out, so they share a menu.
    private var sortItems: [ActionMenuItem] {
        let keys: [ActionMenuItem] = SortKey.allCases.map { key in
            .button(key.title,
                    trailing: vm.sortKey == key ? (vm.sortAscending ? "chevron.up" : "chevron.down") : nil) {
                vm.toggleSort(key)
            }
        }
        let groups: [ActionMenuItem] = ListGrouping.allCases.map { grouping in
            .button(L10n.t("Group by %@", L10n.midSentence(grouping.title)),
                    trailing: vm.grouping == grouping ? "checkmark" : nil) {
                vm.grouping = grouping
            }
        }
        return keys + [ActionMenuItem(kind: .separator)] + groups
    }

    /// Mirrors the sidebar's Status and Type groups, with a checkmark on the active one.
    private var filterItems: [ActionMenuItem] {
        let status = (SidebarCatalog.library + SidebarCatalog.status).map(\.filter)
        let types = SidebarCatalog.types.map(\.filter)
        return status.map(filterItem) + [ActionMenuItem(kind: .separator)] + types.map(filterItem)
    }

    /// At rest the Filter menu; with a filter on, a tinted chip naming it, whose ✕ goes back to All.
    /// Before, nothing in the toolbar said the list was narrowed.
    @ViewBuilder
    private var filterControl: some View {
        if vm.filter == .all {
            ActionMenu(items: filterItems) { open in
                ToolbarMenuLabel(title: L10n.t("Filter"), systemImage: "line.3.horizontal.decrease.circle",
                                 active: open)
            }
            .accessibilityValue(vm.filter.accessibilityName)
        } else {
            HStack(spacing: 0) {
                ActionMenu(items: filterItems) { _ in
                    HStack(spacing: 5) {
                        Image(systemName: "line.3.horizontal.decrease.circle.fill").scaledFont(size: Theme.TextSize.body)
                        Text(vm.filter.accessibilityName)
                            .scaledFont(size: Theme.TextSize.body, weight: .medium)
                            .lineLimit(1)
                    }
                    .padding(.leading, 10)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                    .a11yGroup(label: L10n.t("Filter"),
                               hint: L10n.t("Activate to open the %@ menu.", L10n.midSentence(L10n.t("Filter"))))
                    .accessibilityAddTraits(.isButton)
                }
                .accessibilityValue(vm.filter.accessibilityName)
                IconButton(symbol: "xmark", help: L10n.t("Show all downloads"), size: 9, tint: Theme.accent,
                           spokenLabel: L10n.t("Clear filter")) {
                    vm.filter = .all
                }
                .padding(.trailing, 3)
            }
            .foregroundStyle(Theme.accent)
            .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control).stroke(Theme.accent.opacity(0.35)))
        }
    }

    /// Pause All while anything is running or waiting, Resume All once everything is paused.
    /// Disabled, not hidden, when there is nothing to do, so the toolbar doesn't shift.
    private var pauseResumeAllButton: some View {
        let state = vm.commandState.snapshot
        let pausing = state.pauseAllPauses
        let title = pausing ? L10n.t("Pause All") : L10n.t("Resume All")
        return Button {
            if pausing { vm.pauseAll() } else { vm.resumeAll() }
        } label: {
            Image(systemName: pausing ? "pause.circle" : "play.circle")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(!state.pauseAllEnabled)
        .help(title)
        .a11yButton(title)
    }

    private func filterItem(_ filter: SidebarFilter) -> ActionMenuItem {
        .button(filter.accessibilityName, trailing: vm.filter == filter ? "checkmark" : nil) {
            vm.filter = filter
        }
    }
}

/// The ⌘K hint inside the search field. Once the queue has rows the first-run hint is gone,
/// so this is the palette's only on-screen entry point.
private struct PaletteKeycap: View {
    @State private var hovering = false

    var body: some View {
        Button {
            CommandPaletteBus.toggle()
        } label: {
            Text("⌘K")
                .scaledFont(size: Theme.TextSize.caption, weight: .semibold, design: .rounded)
                .foregroundStyle(hovering ? Theme.accent : Color.secondary)
                .padding(.horizontal, 5)
                .frame(height: 18)
                .background(hovering ? Theme.fillHover : Theme.fillRest,
                            in: RoundedRectangle(cornerRadius: Theme.Radius.chip))
                .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip).stroke(Theme.hairline))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L10n.t("Command palette · ⌘K"))
        .a11yButton(L10n.t("Command palette, Command K"))
    }
}
