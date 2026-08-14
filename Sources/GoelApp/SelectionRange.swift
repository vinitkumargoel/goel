import Foundation

/// Range arithmetic for Finder-style list selection, kept out of the view model so it can be
/// tested without one.
enum SelectionRange {

    /// Every id from `anchor` through `target` inclusive, in the order the list shows them.
    ///
    /// Both ends are looked up in `items` rather than trusted: a sort, a filter or a finished
    /// download can move or drop either one between the click that set the anchor and the click
    /// that extends from it. A vanished anchor degrades to a plain single-row selection — the
    /// alternative, selecting nothing, loses the row the user just shift-clicked.
    static func ids<Item: Identifiable>(in items: [Item],
                                        from anchor: Item.ID?,
                                        through target: Item.ID) -> [Item.ID] {
        guard let end = items.firstIndex(where: { $0.id == target }) else { return [] }
        guard let anchor,
              let start = items.firstIndex(where: { $0.id == anchor }) else { return [target] }
        let bounds = start <= end ? start...end : end...start
        return items[bounds].map(\.id)
    }

    /// The row an arrow key lands on: `offset` rows from `current`, clamped to the list.
    /// With nothing selected, a down key starts at the top and an up key at the bottom.
    static func neighbor<Item: Identifiable>(in items: [Item],
                                             from current: Item.ID?,
                                             offset: Int) -> Item.ID? {
        guard !items.isEmpty else { return nil }
        guard let current, let index = items.firstIndex(where: { $0.id == current }) else {
            return offset > 0 ? items.first?.id : items.last?.id
        }
        return items[min(max(0, index + offset), items.count - 1)].id
    }
}
