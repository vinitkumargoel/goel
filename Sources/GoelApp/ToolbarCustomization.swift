import Foundation
import GoelCore

/// The main window's toolbar items the user can show or hide (right-click the toolbar).
/// Add Download, Select, Sort and Filter always stay: they are how the list is driven.
enum ToolbarSlot: String, CaseIterable, Identifiable, Sendable {
    case pauseResume, remove, speedLimit, profile, linkGrabber, dropBasket, sftp, search, inspector

    var id: String { rawValue }

    static let storageKey = "toolbar.items"

    /// What the toolbar showed before it was customisable.
    static let defaults: Set<ToolbarSlot> = [.pauseResume, .search, .inspector]

    var title: String {
        switch self {
        case .pauseResume: return L10n.t("Pause/Resume All")
        case .remove: return L10n.t("Remove")
        case .speedLimit: return L10n.t("Speed Limit")
        case .profile: return L10n.t("Profile")
        case .linkGrabber: return L10n.t("Link Grabber")
        case .dropBasket: return L10n.t("Drop Basket")
        case .sftp: return L10n.t("SFTP Servers")
        case .search: return L10n.t("Search")
        case .inspector: return L10n.t("Inspector")
        }
    }

    static func decode(_ raw: String) -> Set<ToolbarSlot> {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return defaults }
        if trimmed == "-" { return [] }
        return Set(trimmed.split(separator: ",").compactMap { ToolbarSlot(rawValue: String($0)) })
    }

    static func encode(_ set: Set<ToolbarSlot>) -> String {
        let ordered = allCases.filter(set.contains).map(\.rawValue)
        return ordered.isEmpty ? "-" : ordered.joined(separator: ",")
    }

    static func toggling(_ slot: ToolbarSlot, in raw: String) -> String {
        var set = decode(raw)
        if set.contains(slot) { set.remove(slot) } else { set.insert(slot) }
        return encode(set)
    }
}

/// Whether the header shows the full omnibox. With Search hidden it folds to a magnifier, but it
/// still unfolds whenever it has something to show: the user opened it (click or ⌘F), it holds
/// text (a search or links being added), or it carries the copied-link suggestion. So paste-to-add
/// keeps working with Search hidden.
enum HeaderSearch {
    static func showsOmnibox(searchShown: Bool, isOpened: Bool, text: String,
                             hasClipboardSuggestion: Bool) -> Bool {
        searchShown || isOpened || !text.isEmpty || hasClipboardSuggestion
    }
}
