import SwiftUI
import GoelCore

/// The custom in-window toolbar: Add, Select, Sort, Filter, a search field, and
/// the detail-panel toggle.
struct AppToolbar: View {
    @EnvironmentObject private var vm: AppViewModel

    var body: some View {
        HStack(spacing: 8) {
            Button {
                vm.isAddSheetPresented = true
            } label: {
                Label("Add download", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("n", modifiers: .command)

            Divider().frame(height: 20)

            ActionMenu(items: [
                .button("Select all") { vm.selectAll() },
                .button("Select none") { vm.selectNone() },
                .button("Select completed") { vm.selectCompleted() },
            ]) { open in
                ToolbarMenuLabel(title: "Select", systemImage: "checkmark.circle", active: open)
            }
            .accessibilityValue("\(vm.selection.count) selected")

            ActionMenu(items: sortItems) { open in
                ToolbarMenuLabel(title: "Sort", systemImage: "arrow.up.arrow.down", active: open)
            }
            // The active sort key and direction are otherwise shown only as a
            // chevron inside the (closed) popover.
            .accessibilityValue("\(vm.sortKey.accessibilityName), \(vm.sortAscending ? "ascending" : "descending")")

            ActionMenu(items: [
                .button("All files") { vm.filter = .all },
                .button("Active") { vm.filter = .active },
                .button("Paused") { vm.filter = .paused },
                .button("Completed") { vm.filter = .completed },
                .button("Seeding") { vm.filter = .seeding },
            ]) { open in
                ToolbarMenuLabel(title: "Filter", systemImage: "line.3.horizontal.decrease.circle", active: open)
            }
            .accessibilityValue(vm.filter.accessibilityName)

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 12))
                    // The placeholder text already says "Search downloads".
                    .a11yDecorative()
                TextField("Search downloads", text: $vm.search)
                    .textFieldStyle(.plain)
                    .frame(width: 180)
                    // A placeholder disappears the moment the field has text, so
                    // it can't be the only name the field has.
                    .accessibilityLabel("Search downloads")
                    // ⌘F is the universal "find" gesture and the field was
                    // previously only reachable by clicking it or tabbing the
                    // whole toolbar.
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
            .help("Toggle detail panel")
            .tint(vm.detailPanelVisible ? Theme.accent : nil)
            .keyboardShortcut("i", modifiers: [.command, .option])
            // Icon-only, and its on/off state is carried purely by the accent
            // tint — invisible to VoiceOver and to a colour-blind user alike.
            .a11yButton("Detail panel")
            .accessibilityValue(vm.detailPanelVisible ? "Shown" : "Hidden")
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(.bar)
    }

    /// Sort rows, with an up/down chevron marking the active key's direction.
    private var sortItems: [ActionMenuItem] {
        SortKey.allCases.map { key in
            .button(key.rawValue,
                    trailing: vm.sortKey == key ? (vm.sortAscending ? "chevron.up" : "chevron.down") : nil) {
                vm.toggleSort(key)
            }
        }
    }
}
