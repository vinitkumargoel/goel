import CoreGraphics

/// The main window's region widths and the decisions that follow from the window's width,
/// kept pure so the thresholds are tested rather than eyeballed.
enum WindowLayout {
    /// The icon rail, expanded (labels) and collapsed (icons only).
    static let sidebarWidth: CGFloat = 212
    static let collapsedSidebarWidth: CGFloat = 68
    /// The floating detail sheet and the margin between it and the window's trailing edge.
    static let detailSheetWidth: CGFloat = 372
    static let detailSheetMargin: CGFloat = 14
    /// What a right-docked detail sheet takes from the content: the board and list reflow into
    /// the rest instead of sliding under the sheet.
    static let detailPanelWidth: CGFloat = detailSheetWidth + detailSheetMargin
    /// The narrowest list worth keeping beside a right-docked panel: the compact column set
    /// with its name at the minimum.
    static let listMinimumBesideDetail: CGFloat = 440
    static let minimumListWidth: CGFloat = 420
    static let minimumWindowWidth: CGFloat = 820
    static let minimumWindowHeight: CGFloat = 620

    /// Where the detail panel actually docks. A right dock that would squeeze the list below
    /// ``listMinimumBesideDetail`` moves under it instead; the user's preference is untouched,
    /// so widening the window brings the panel back to the right.
    static func detailPosition(preferred: DetailPanelPosition, windowWidth: CGFloat,
                               sidebarVisible: Bool) -> DetailPanelPosition {
        guard preferred == .right, windowWidth.isFinite, windowWidth > 0 else { return preferred }
        let sidebar = (sidebarVisible ? sidebarWidth : collapsedSidebarWidth) + 1
        let list = windowWidth - sidebar - detailPanelWidth - 1
        return list >= listMinimumBesideDetail ? .right : .bottom
    }
}
