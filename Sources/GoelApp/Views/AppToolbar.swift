import SwiftUI
import GoelCore

struct AppToolbar: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        HStack(spacing: 8) {
            Button {
                vm.isAddSheetPresented = true
            } label: {
                Label(L10n.t("Add download"), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("n", modifiers: .command)

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
            .accessibilityValue(L10n.t("%1$@, %2$@", L10n.t(vm.sortKey.accessibilityName),
                                      vm.sortAscending ? L10n.t("ascending") : L10n.t("descending")))

            ActionMenu(items: [
                .button(L10n.t("All files")) { vm.filter = .all },
                .button(L10n.t("Active")) { vm.filter = .active },
                .button(L10n.t("Paused")) { vm.filter = .paused },
                .button(L10n.t("Completed")) { vm.filter = .completed },
                .button(L10n.t("Seeding")) { vm.filter = .seeding },
            ]) { open in
                ToolbarMenuLabel(title: L10n.t("Filter"), systemImage: "line.3.horizontal.decrease.circle", active: open)
            }
            .accessibilityValue(vm.filter.accessibilityName)

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 12))
                    .a11yDecorative()
                TextField(L10n.t("Search downloads"), text: $vm.search)
                    .textFieldStyle(.plain)
                    .frame(width: 180)
                    .accessibilityLabel(L10n.t("Search downloads"))
                    .keyboardShortcut("f", modifiers: .command)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))

            Button {
                vm.detailPanelVisible.toggle()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help(L10n.t("Toggle detail panel"))
            .tint(vm.detailPanelVisible ? Theme.accent : nil)
            .keyboardShortcut("i", modifiers: [.command, .option])
            .a11yButton(L10n.t("Detail panel"))
            .accessibilityValue(vm.detailPanelVisible ? L10n.t("Shown") : L10n.t("Hidden"))
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(.bar)
    }

    private var sortItems: [ActionMenuItem] {
        SortKey.allCases.map { key in
            .button(key.rawValue,
                    trailing: vm.sortKey == key ? (vm.sortAscending ? "chevron.up" : "chevron.down") : nil) {
                vm.toggleSort(key)
            }
        }
    }
}
