import Foundation

/// The sidebar's fixed filters in on-screen order. One list feeds the sidebar, the toolbar's
/// Filter menu and the ⌘1…⌘9 shortcuts, so a new entry can't land in one and not the others,
/// and the numbers always count down the sidebar as drawn.
struct SidebarEntry: Identifiable {
    let filter: SidebarFilter
    let symbol: String

    var id: String { title }
    var title: String { filter.accessibilityName }
}

enum SidebarCatalog {

    static let library: [SidebarEntry] = [
        SidebarEntry(filter: .all, symbol: "tray.full"),
    ]

    static let status: [SidebarEntry] = [
        SidebarEntry(filter: .active, symbol: "arrow.down.circle"),
        SidebarEntry(filter: .queued, symbol: "clock"),
        SidebarEntry(filter: .paused, symbol: "pause.circle"),
        SidebarEntry(filter: .completed, symbol: "checkmark.circle"),
        SidebarEntry(filter: .seeding, symbol: "arrow.up.circle"),
        SidebarEntry(filter: .failed, symbol: "exclamationmark.triangle"),
    ]

    /// Magnets are a transient state, not a kind of file, so they get no sidebar entry.
    static let types: [SidebarEntry] = FileType.allCases
        .filter { $0 != .magnet }
        .map { SidebarEntry(filter: .type($0), symbol: $0.symbol) }

    static var all: [SidebarEntry] { library + status + types }

    /// ⌘1 is the first entry, ⌘9 the ninth; the rest have no shortcut.
    static var shortcutFilters: [SidebarFilter] { Array(all.prefix(9).map(\.filter)) }
}
