import SwiftUI
import GoelCore

/// The content header's menus as nodes: Sort, Group by, Select, Type, and the column menu the
/// List's header shows on right-click.
@MainActor
enum DownloadsHeaderMenus {

    /// Every sort key (picking the current one reverses it), then the direction.
    static func sortNodes(_ vm: AppViewModel) -> [DownloadMenuNode] {
        let keys: [DownloadMenuNode] = SortKey.allCases.map { key in
            let current = vm.sortKey == key
            return .toggle(key.title, trailing: current ? (vm.sortAscending ? "↑" : "↓") : nil,
                           isOn: current) { _ in
                vm.toggleSort(key)
            }
        }
        return keys + [
            .divider,
            .choice(L10n.t("Ascending"), isOn: vm.sortAscending) { vm.sortAscending = true },
            .choice(L10n.t("Descending"), isOn: !vm.sortAscending) { vm.sortAscending = false },
        ]
    }

    static func groupNodes(_ vm: AppViewModel) -> [DownloadMenuNode] {
        ListGrouping.allCases.map { grouping in
            .choice(grouping.title, isOn: vm.grouping == grouping) { vm.grouping = grouping }
        }
    }

    static func selectNodes(_ vm: AppViewModel) -> [DownloadMenuNode] {
        [
            .button(L10n.t("Select all"), symbol: "checkmark.circle") { vm.selectAll() },
            .button(L10n.t("Select none"), symbol: "circle") { vm.selectNone() },
            .button(L10n.t("Select completed"), symbol: "checkmark.seal") { vm.selectCompleted() },
            .divider,
            // Off the list, not off the disk; the toast that follows offers Undo.
            .button(L10n.t("Clear completed"), symbol: "xmark.bin") { vm.clearCompleted() },
        ]
    }

    /// The type filters with their counts; the same list the rail's types come from.
    static func typeNodes(_ vm: AppViewModel) -> [DownloadMenuNode] {
        SidebarCatalog.types.map { entry in
            .choice(entry.title, trailing: "\(vm.count(for: entry.filter))", isOn: vm.filter == entry.filter) {
                vm.filter = entry.filter
            }
        }
    }

    /// One checkable item per column, then row density, then Reset.
    static func columnNodes(columnsRaw: Binding<String>, density: Binding<ListDensity>) -> [DownloadMenuNode] {
        let chosen = ListColumnPrefs.decode(columnsRaw.wrappedValue)
        let columns: [DownloadMenuNode] = ListColumn.allCases.map { column in
            .toggle(column.title, isOn: chosen.contains(column)) { _ in
                columnsRaw.wrappedValue = ListColumnPrefs.toggling(column, in: columnsRaw.wrappedValue)
            }
        }
        let densities: [DownloadMenuNode] = ListDensity.allCases.map { option in
            .choice(option.title, trailing: option == .compact ? "⌥⌘C" : nil,
                    isOn: density.wrappedValue == option) {
                density.wrappedValue = option
            }
        }
        return [
            .section(L10n.t("Columns"), columns),
            .divider,
            .section(L10n.t("Row Density"), densities),
            .divider,
            .button(L10n.t("Reset Columns")) { columnsRaw.wrappedValue = "" },
        ]
    }
}
