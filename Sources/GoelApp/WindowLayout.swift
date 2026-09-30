import CoreGraphics

/// The main window's region widths and the decisions that follow from the window's width,
/// kept pure so the thresholds are tested rather than eyeballed.
enum WindowLayout {
    static let sidebarWidth: CGFloat = 200
    static let detailPanelWidth: CGFloat = 340
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
        let sidebar = sidebarVisible ? sidebarWidth + 1 : 0
        let list = windowWidth - sidebar - detailPanelWidth - 1
        return list >= listMinimumBesideDetail ? .right : .bottom
    }
}
