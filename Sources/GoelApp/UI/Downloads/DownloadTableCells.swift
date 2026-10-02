import SwiftUI
import GoelCore

/// The Status column: a pill in the state's colour. A failure reads "Failed" with a glyph, not
/// just a red dot, so it survives "Differentiate without colour"; compact rows, which have no
/// line under the name, put the reason here, two lines deep.
struct DownloadStatusCell: View {
    let task: DownloadTask
    let speed: SpeedSample
    let queueRank: Int?
    /// No Speed column: the rate leads the status ("↓ 7.7 MB/s · 1m left").
    let foldsSpeed: Bool
    let showsReason: Bool

    var body: some View {
        if let reason = task.failureMessage {
            VStack(alignment: .leading, spacing: Studio.Space.hair) {
                Label(L10n.t("Failed"), systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(StudioButtonLabelStyle(spacing: Studio.Space.xxs, iconSize: 10))
                    .studioFont(Studio.TextStyle.caption.weight(650))
                    .foregroundStyle(Studio.Palette.bad)
                    .padding(.horizontal, 9)
                    .frame(minHeight: 22)
                    .background(Studio.Palette.badSoft, in: Capsule())
                    .lineLimit(1)
                if showsReason {
                    Text(reason)
                        .studioFont(.tiny)
                        .foregroundStyle(Studio.Palette.ink2)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            HStack(spacing: 5) {
                DownloadStatusPill(text: text, tone: StudioDownloadState(task: task).tone)
                    .layoutPriority(1)
                if let progress = task.seedTargetProgress {
                    SeedTargetBar(progress: progress, width: 18)
                }
            }
        }
    }

    private var text: String {
        foldsSpeed ? task.statusFoldedText(speed: speed, queueRank: queueRank)
                   : task.statusCompactText(queueRank: queueRank)
    }
}

/// One column for both directions: ↓ on top, ↑ under it while something is uploading.
struct DownloadSpeedCell: View {
    let task: DownloadTask
    let speed: SpeedSample

    var body: some View {
        let text = SpeedCellText(speed: speed, isTorrent: task.kind == .torrent)
        VStack(alignment: .trailing, spacing: 1) {
            if let down = text.down {
                Text(down)
                    .studioMono(size: 11.5, weight: 600)
                    .foregroundStyle(Studio.Palette.accent)
            }
            if let up = text.up {
                Text(up)
                    .studioMono(size: text.down == nil ? 11.5 : 10.5, weight: text.down == nil ? 600 : 500)
                    .foregroundStyle(speed.up >= 1 ? Studio.Palette.upload : Studio.Palette.ink3)
            }
            if text.isEmpty {
                Text(verbatim: "—")
                    .studioMono()
                    .foregroundStyle(Studio.Palette.ink3)
                    .a11yDecorative()
            }
        }
        .lineLimit(1)
    }
}

/// A non-sorting header label for an extra column (see ``ListColumn/sortKey``).
struct ExtraColumnHeader: View {
    let column: ListColumn
    let width: CGFloat

    var body: some View {
        Text(column.title)
            .lineLimit(1)
            .frame(width: width, alignment: column.cellAlignment)
            .padding(.horizontal, Studio.Space.xs)
            .accessibilityAddTraits(.isHeader)
    }
}

/// One extra column's value for a row. Plain text, so the row stays cheap to diff.
struct ExtraColumnCell: View {
    let column: ListColumn
    let task: DownloadTask

    var body: some View {
        Text(value)
            .studioFont(column == .tags || column == .host ? .small : .monoBody)
            .foregroundStyle(value == "—" ? Studio.Palette.ink3 : Studio.Palette.ink2)
            .lineLimit(1)
            .truncationMode(column == .savePath ? .head : .tail)
            .help(column == .savePath ? task.savePath : value)
    }

    private var value: String { ExtraColumnText.value(column, task: task) }
}

/// A Group by header: pinned while its rows scroll under it.
struct ListSectionHeader: View {
    let section: ListSection

    var body: some View {
        HStack(spacing: Studio.Space.xs) {
            Text(section.title)
                .studioFont(.eyebrow)
                .foregroundStyle(Studio.Palette.ink3)
                .lineLimit(1)
            Spacer(minLength: Studio.Space.s)
            Text(summary)
                .studioFont(.monoSmall)
                .foregroundStyle(Studio.Palette.ink3)
                .lineLimit(1)
        }
        .padding(.horizontal, 18)
        .padding(.top, Studio.Space.sm)
        .padding(.bottom, Studio.Space.xxs)
        .frame(maxWidth: .infinity)
        .background(Studio.Palette.card)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(A11y.sentence(section.title, spokenSummary))
        .accessibilityAddTraits(.isHeader)
    }

    /// "12 · 4.2 GB"; the size is left off while nothing in the group has a known size.
    private var summary: String {
        let total = section.totalBytes
        return total > 0 ? L10n.t("%1$d · %2$@", section.tasks.count, total.byteString) : "\(section.tasks.count)"
    }

    private var spokenSummary: String {
        let count = section.tasks.count == 1
            ? L10n.t("%d download", section.tasks.count)
            : L10n.t("%d downloads", section.tasks.count)
        let total = section.totalBytes
        return total > 0 ? A11y.sentence(count, A11y.bytes(total)) : count
    }
}

/// The List's column header: click to sort, again to reverse; right-click for the column menu.
struct DownloadTableHeader: View {
    @EnvironmentObject private var vm: AppViewModel
    let columns: DownloadColumns
    @Binding var columnsRaw: String
    @Binding var density: ListDensity

    var body: some View {
        HStack(spacing: 0) {
            sortable(.index, width: columns.index, alignment: .center)
            sortable(.name, width: nil, alignment: .leading)
            if columns.showsSize { sortable(.size, width: columns.size, alignment: .trailing) }
            if columns.showsStatus { sortable(.status, width: columns.status, alignment: .leading) }
            if columns.showsAdded { sortable(.added, width: columns.added, alignment: .trailing) }
            ForEach(columns.extras) { extra in
                if let key = extra.sortKey {
                    sortable(key, width: columns.width(of: extra), alignment: extra.cellAlignment, title: extra.title)
                } else {
                    ExtraColumnHeader(column: extra, width: columns.width(of: extra))
                }
            }
            if columns.showsSpeed {
                // One column for both directions; it sorts by download speed. The Sort menu can
                // still pick upload speed, and the chevron shows here then too.
                sortable(.downloadSpeed, width: columns.speed, alignment: .trailing,
                         title: L10n.t("Speed"), alsoSortedBy: [.uploadSpeed])
            }
            // Over the rows' action buttons; they need no heading.
            Color.clear
                .frame(width: columns.action, height: 1)
                .padding(.horizontal, Studio.Space.xs)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, Studio.Space.m)
        .frame(minHeight: 32)
        .studioFont(Studio.TextStyle.tiny.weight(650))
        .foregroundStyle(Studio.Palette.ink3)
        .contentShape(Rectangle())
        .contextMenu {
            DownloadMenuContent(nodes: DownloadsHeaderMenus.columnNodes(columnsRaw: $columnsRaw, density: $density))
        }
    }

    private func sortable(_ key: SortKey, width: CGFloat?, alignment: Alignment,
                          title: String? = nil, alsoSortedBy: [SortKey] = []) -> some View {
        let isSortKey = vm.sortKey == key || alsoSortedBy.contains(vm.sortKey)
        let ascending = vm.sortAscending
        return Button {
            vm.toggleSort(key)
        } label: {
            HStack(spacing: 3) {
                if alignment == .trailing { Spacer(minLength: 0) }
                Text(title ?? key.columnTitle)
                    .lineLimit(1)
                    .foregroundStyle(isSortKey ? Studio.Palette.ink : Studio.Palette.ink3)
                if isSortKey {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down")
                        .studioFont(.ui, size: 8, weight: 800)
                        .foregroundStyle(Studio.Palette.accent)
                }
                if alignment != .trailing { Spacer(minLength: 0) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(width: width, alignment: alignment)
        .frame(maxWidth: width == nil ? .infinity : nil)
        .padding(.horizontal, Studio.Space.xs)
        .a11yButton(title ?? key.title,
                    hint: isSortKey
                        ? L10n.t("Currently sorting %@. Activate to reverse.",
                                 ascending ? L10n.t("ascending") : L10n.t("descending"))
                        : L10n.t("Activate to sort by this column."))
        .accessibilityValue(isSortKey
                            ? (ascending ? L10n.t("Sorted ascending") : L10n.t("Sorted descending"))
                            : L10n.t("Not sorted"))
    }
}
