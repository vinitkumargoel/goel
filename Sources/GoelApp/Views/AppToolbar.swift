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

            Menu {
                Button("Select all") { vm.toast = "Selected all \(vm.tasks.count) downloads" }
                Button("Select none") { vm.selection = nil }
            } label: {
                Label("Select", systemImage: "checkmark.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Menu {
                ForEach(SortKey.allCases) { key in
                    Button {
                        vm.toggleSort(key)
                    } label: {
                        HStack {
                            Text(key.rawValue)
                            if vm.sortKey == key {
                                Image(systemName: vm.sortAscending ? "chevron.up" : "chevron.down")
                            }
                        }
                    }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Menu {
                Button("All files") { vm.filter = .all }
                Button("Active") { vm.filter = .active }
                Button("Paused") { vm.filter = .paused }
                Button("Completed") { vm.filter = .completed }
                Button("Seeding") { vm.filter = .seeding }
            } label: {
                Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 12))
                TextField("Search downloads", text: $vm.search)
                    .textFieldStyle(.plain)
                    .frame(width: 180)
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
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .background(.bar)
    }
}
