import Foundation

/// Range arithmetic for Finder-style list selection, kept out of the view model so it can be
/// tested without one.
enum SelectionRange {

    /// The selection with every row the list no longer shows taken out, so the detail panel
    /// never keeps describing a row that a filter or search just hid. A hidden primary row hands
    /// over to the first still-selected row in list order; with none left, nothing is selected.
    static func pruned<ID: Hashable>(selection: Set<ID>, primary: ID?, anchor: ID?,
                                     visible: [ID]) -> (selection: Set<ID>, primary: ID?, anchor: ID?) {
        let shown = Set(visible)
        let kept = selection.intersection(shown)
        let fallback = visible.first(where: kept.contains)
        let nextPrimary = primary.flatMap { shown.contains($0) ? $0 : nil } ?? fallback
        let nextAnchor = anchor.flatMap { kept.contains($0) ? $0 : nil } ?? nextPrimary
        return (kept, nextPrimary, nextAnchor)
    }

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
