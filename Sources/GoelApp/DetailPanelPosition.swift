import Foundation

/// Where the detail panel docks in the main window. Stored in `AppSettings.detailPanelPosition`
/// as `"right"` or `"bottom"`.
enum DetailPanelPosition: String, CaseIterable, Identifiable {
    case right = "Right"
    case bottom = "Bottom"
    var id: String { rawValue }

    var settingsValue: String { rawValue.lowercased() }

    init(settingsValue: String) {
        self = DetailPanelPosition.allCases.first { $0.settingsValue == settingsValue } ?? .right
    }
}
