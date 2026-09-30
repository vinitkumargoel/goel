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
            ]) { open in
                ToolbarMenuLabel(title: L10n.t("Select"), systemImage: "checkmark.circle", active: open)
            }
            .accessibilityValue(L10n.t("%d selected", vm.selection.count))

            ActionMenu(items: sortItems) { open in
                ToolbarMenuLabel(title: L10n.t("Sort"), systemImage: "arrow.up.arrow.down", active: open)
            }
            .accessibilityValue(L10n.t("%1$@, %2$@", vm.sortKey.title,
                                      vm.sortAscending ? L10n.t("ascending") : L10n.t("descending")))

            ActionMenu(items: filterItems) { open in
                ToolbarMenuLabel(title: L10n.t("Filter"), systemImage: "line.3.horizontal.decrease.circle", active: open)
            }
            .accessibilityValue(vm.filter.accessibilityName)

            Spacer()

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
                .font(.system(size: 12))
                .a11yDecorative()
            TextField(L10n.t("Search downloads"), text: $vm.search)
                .textFieldStyle(.plain)
                .scaledFont(size: Theme.TextSize.body)
                .frame(width: 180)
                .accessibilityLabel(L10n.t("Search downloads"))
                .focused($searchFocused)
                .help(ShortcutHint.help(L10n.t("Search downloads"), "⌘F"))
                .onExitCommand {
                    // Escape clears, then a second Escape hands the keyboard back to the list.
                    if vm.search.isEmpty { searchFocused = false } else { vm.search = "" }
                }
            PaletteKeycap()
        }
        .onReceive(NotificationCenter.default.publisher(for: FocusBus.focusSearch)) { _ in
            searchFocused = true
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
        .frame(height: 28)
        .background(Theme.fillRest, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
    }

    private var sortItems: [ActionMenuItem] {
        SortKey.allCases.map { key in
            .button(key.title,
                    trailing: vm.sortKey == key ? (vm.sortAscending ? "chevron.up" : "chevron.down") : nil) {
                vm.toggleSort(key)
            }
        }
    }

    /// Mirrors the sidebar's Status and Type groups, with a checkmark on the active one.
    private var filterItems: [ActionMenuItem] {
        let status: [SidebarFilter] = [.all, .active, .paused, .completed, .seeding, .failed]
        let types: [SidebarFilter] = [.type(.video), .type(.iso), .type(.archive), .type(.app)]
        return status.map(filterItem) + [ActionMenuItem(kind: .separator)] + types.map(filterItem)
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
