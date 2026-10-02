import Foundation
import CoreGraphics
import SwiftUI
import GoelCore

/// The list's fixed column widths, scaled with the text size. A value, so rows compare it.
struct DownloadColumns: Equatable {
    var index: CGFloat = 30
    var size: CGFloat = 84
    var status: CGFloat = 150
    var added: CGFloat = 96
    var speed: CGFloat = 92
    var layout: Layout = .full
    /// What the header's context menu switched on; width can still hide any of them.
    var chosen: Set<ListColumn> = ListColumn.defaults
    /// Extra columns that fit after the core ones, in ``ListColumn/extras`` order.
    var extras: [ListColumn] = []
    var density: ListDensity = .regular
    var scale: CGFloat = 1

    /// Which columns fit. Narrower lists shed Added first, then fold Size under the name and
    /// Speed into Status, so the name never drops below ``minimumNameWidth``.
    enum Layout: Equatable {
        case full
        case noAdded
        case compact
    }

    static let minimumNameWidth: CGFloat = 180
    /// Each cell's 6 pt of padding on both sides.
    static let cellPadding: CGFloat = 12
    /// The row's 12 pt on both sides.
    static let rowPadding: CGFloat = 24

    init(scale: CGFloat = 1, listWidth: CGFloat? = nil,
         chosen: Set<ListColumn> = ListColumn.defaults, density: ListDensity = .regular) {
        let s = scale.isFinite && scale > 0 ? scale : 1
        self.scale = s
        self.chosen = chosen
        self.density = density
        index = (index * s).rounded()
        size = (size * s).rounded()
        status = (status * s).rounded()
        added = (added * s).rounded()
        speed = (speed * s).rounded()
        guard let listWidth else {
            extras = ListColumn.extras.filter(chosen.contains)
            return
        }
        layout = Self.layout(for: listWidth, columns: effectiveCore)
        extras = Self.fittingExtras(listWidth: listWidth, columns: self)
    }

    /// The core widths with unchosen columns collapsed, padding included, so they cost nothing.
    private var effectiveCore: DownloadColumns {
        var copy = self
        if !chosen.contains(.size) { copy.size = -Self.cellPadding }
        if !chosen.contains(.status) { copy.status = -Self.cellPadding }
        if !chosen.contains(.added) { copy.added = -Self.cellPadding }
        if !chosen.contains(.speed) { copy.speed = -Self.cellPadding }
        return copy
    }

    var showsSize: Bool { chosen.contains(.size) && layout != .compact }
    var showsAdded: Bool { chosen.contains(.added) && layout == .full }
    var showsSpeed: Bool { chosen.contains(.speed) && layout != .compact }
    var showsStatus: Bool { chosen.contains(.status) }

    func width(of extra: ListColumn) -> CGFloat { (extra.baseWidth * scale).rounded() }

    /// Width the core columns take once the width-driven layout has run.
    var coreWidth: CGFloat {
        var total = index + Self.cellPadding + Self.rowPadding + Self.cellPadding
        if showsStatus { total += status + Self.cellPadding }
        if showsSize { total += size + Self.cellPadding }
        if showsAdded { total += added + Self.cellPadding }
        if showsSpeed { total += speed + Self.cellPadding }
        return total
    }

    /// Extras are added in priority order while the name keeps ``minimumNameWidth``; an
    /// unmeasured list shows all of them rather than flashing a reduced set.
    static func fittingExtras(listWidth: CGFloat, columns: DownloadColumns) -> [ListColumn] {
        let wanted = ListColumn.extras.filter(columns.chosen.contains)
        guard listWidth.isFinite, listWidth > 0 else { return wanted }
        var room = listWidth - columns.coreWidth - minimumNameWidth
        var shown: [ListColumn] = []
        for column in wanted {
            let cost = columns.width(of: column) + cellPadding
            guard cost <= room else { continue }
            room -= cost
            shown.append(column)
        }
        return shown
    }

    /// The widest set whose fixed columns still leave the name its minimum. An unmeasured
    /// (zero) width keeps the full set rather than flashing the compact one on first layout.
    static func layout(for listWidth: CGFloat, columns: DownloadColumns) -> Layout {
        guard listWidth.isFinite, listWidth > 0 else { return .full }
        let chrome = rowPadding + cellPadding
        let base = columns.index + columns.status + 2 * cellPadding + chrome
        let full = base + columns.size + columns.added + columns.speed + 3 * cellPadding
        if listWidth >= full + minimumNameWidth { return .full }
        let noAdded = full - columns.added - cellPadding
        if listWidth >= noAdded + minimumNameWidth { return .noAdded }
        return .compact
    }
}

extension ListColumn {
    var cellAlignment: Alignment {
        switch self {
        case .eta, .ratio, .peers, .size, .speed: return .trailing
        default: return .leading
        }
    }
}

/// The text behind each extra column, kept out of the view so it can be tested.
enum ExtraColumnText {
    static func value(_ column: ListColumn, task: DownloadTask) -> String {
        switch column {
        case .eta:
            guard let eta = task.estimatedTimeRemaining, eta > 0 else { return "—" }
            return DownloadTask.etaString(eta)
        case .ratio:
            return task.kind == .torrent ? String(format: "%.2f", task.shareRatio) : "—"
        case .peers:
            guard task.kind == .torrent else { return "—" }
            return "\(task.seedCount ?? 0)/\(task.leecherCount)"
        case .host:
            return task.sourceHost ?? "—"
        case .tags:
            let tags = task.tags ?? []
            return tags.isEmpty ? "—" : tags.joined(separator: ", ")
        case .savePath:
            return (task.saveDirectory as NSString).abbreviatingWithTildeInPath
        case .protocol:
            return protocolName(task.kind)
        case .size, .status, .speed, .added:
            return ""
        }
    }

    static func protocolName(_ kind: DownloadKind) -> String {
        switch kind {
        case .http: return "HTTP"
        case .torrent: return "BitTorrent"
        case .hls: return "HLS"
        case .ftp: return "FTP"
        case .sftp: return "SFTP"
        }
    }
}
