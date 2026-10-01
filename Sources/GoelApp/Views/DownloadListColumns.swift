import SwiftUI
import GoelCore

/// Right-click on the list header: one checkable item per column, then row density.
struct ListColumnMenu: View {
    @Binding var columnsRaw: String
    @Binding var density: ListDensity

    var body: some View {
        Section(L10n.t("Columns")) {
            ForEach(ListColumn.allCases) { column in
                Toggle(column.title, isOn: binding(for: column))
            }
        }
        Divider()
        Picker(L10n.t("Row Density"), selection: $density) {
            ForEach(ListDensity.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.inline)
        Divider()
        Button(L10n.t("Reset Columns")) { columnsRaw = "" }
    }

    private func binding(for column: ListColumn) -> Binding<Bool> {
        Binding(
            get: { ListColumnPrefs.decode(columnsRaw).contains(column) },
            set: { _ in columnsRaw = ListColumnPrefs.toggling(column, in: columnsRaw) })
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

/// A non-sorting header label for an extra column.
struct ExtraColumnHeader: View {
    let column: ListColumn
    let width: CGFloat

    var body: some View {
        Text(column.title)
            .lineLimit(1)
            .frame(width: width, alignment: column.cellAlignment)
            .padding(.horizontal, 6)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One extra column's value for a row. Plain text, so the row stays cheap to diff.
struct ExtraColumnCell: View {
    let column: ListColumn
    let task: DownloadTask
    let speed: SpeedSample

    var body: some View {
        Text(value)
            .scaledFont(size: Theme.TextSize.meta, monospacedDigit: true)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(column == .savePath ? .head : .tail)
            .help(tooltip)
    }

    private var value: String { ExtraColumnText.value(column, task: task) }

    private var tooltip: String {
        column == .savePath ? task.savePath : value
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
