import Foundation
import CoreGraphics
import GoelCore

/// A column the user can switch on or off from the list header's context menu. Name and "#"
/// are always shown, so they are not here.
enum ListColumn: String, CaseIterable, Identifiable, Sendable {
    case size, status, speed, added, eta, ratio, peers, host, tags, savePath, `protocol`

    var id: String { rawValue }

    var title: String {
        switch self {
        case .size: return L10n.t("Size")
        case .status: return L10n.t("Status")
        case .speed: return L10n.t("Speed")
        case .added: return L10n.t("Added")
        case .eta: return L10n.t("ETA")
        case .ratio: return L10n.t("Ratio")
        case .peers: return L10n.t("Seeds/Peers")
        case .host: return L10n.t("Source host")
        case .tags: return L10n.t("Tags")
        case .savePath: return L10n.t("Save path")
        case .protocol: return L10n.t("Protocol")
        }
    }

    /// What an untouched install shows: the four core columns plus ETA (shed first when narrow).
    /// Only applies while nothing is stored, so a customised set is never changed behind the user.
    static let defaults: Set<ListColumn> = [.size, .status, .speed, .added, .eta]

    /// The optional columns, in the order they are shed when the list is too narrow (last first).
    static let extras: [ListColumn] = [.eta, .ratio, .peers, .protocol, .tags, .host, .savePath]

    /// Unscaled width of an extra column; the core four keep ``DownloadColumns``' widths.
    var baseWidth: CGFloat {
        switch self {
        case .eta: return 70
        case .ratio: return 54
        case .peers: return 70
        case .host: return 120
        case .tags: return 110
        case .savePath: return 160
        case .protocol: return 90
        case .size: return 104
        case .status: return 150
        case .speed: return 92
        case .added: return 118
        }
    }
}

/// The chosen column set, stored as a comma-separated string in `@AppStorage`.
enum ListColumnPrefs {
    static let storageKey = "list.columns"

    /// Empty storage means "never customised": the defaults, not an empty list.
    static func decode(_ raw: String) -> Set<ListColumn> {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return ListColumn.defaults }
        if trimmed == "-" { return [] }
        return Set(trimmed.split(separator: ",").compactMap { ListColumn(rawValue: String($0)) })
    }

    /// Stable order so the stored string does not churn; "-" records a deliberately empty set.
    static func encode(_ set: Set<ListColumn>) -> String {
        let ordered = ListColumn.allCases.filter(set.contains).map(\.rawValue)
        return ordered.isEmpty ? "-" : ordered.joined(separator: ",")
    }

    static func toggling(_ column: ListColumn, in raw: String) -> String {
        var set = decode(raw)
        if set.contains(column) { set.remove(column) } else { set.insert(column) }
        return encode(set)
    }
}

/// Row height: Regular is the two-line row; Compact is one line with a thin inline bar.
enum ListDensity: String, CaseIterable, Identifiable, Sendable {
    case regular, compact

    static let storageKey = "list.density"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .regular: return L10n.t("Regular")
        case .compact: return L10n.t("Compact")
        }
    }

    var rowHeight: CGFloat { self == .compact ? 24 : 50 }

    var toggled: ListDensity { self == .compact ? .regular : .compact }
}

extension ListDensity {
    /// The View menu and palette flip density outside any view; `@AppStorage` picks it up.
    static var stored: ListDensity {
        UserDefaults.standard.string(forKey: storageKey).flatMap(ListDensity.init(rawValue:)) ?? .regular
    }

    static func toggleStored() {
        UserDefaults.standard.set(stored.toggled.rawValue, forKey: storageKey)
    }
}
