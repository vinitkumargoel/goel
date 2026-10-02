import SwiftUI
import GoelCore

/// One remote item as a list row: artwork, name (and a transfer in progress), size, date.
/// The column widths are mirrored in ``SFTPColumnHeader``; change both together.
struct SFTPEntryRow: View {
    let entry: SFTPEntry
    let isSelected: Bool
    let isHovered: Bool
    let isDropTarget: Bool
    var activity: SFTPTransfer?

    static let sizeWidth: CGFloat = 84
    static let dateWidth: CGFloat = 112

    var body: some View {
        HStack(spacing: Studio.Space.m) {
            SFTPEntryArtwork(entry: entry, size: .xs)
            VStack(alignment: .leading, spacing: 3) {
                FileNameText(entry.name, lineLimit: 1)
                    .studioFont(.body.weight(isSelected ? 600 : 500))
                    .foregroundStyle(Studio.Palette.ink)
                if let activity {
                    HStack(spacing: Studio.Space.s) {
                        StudioLinearProgress(fraction: activity.total > 0 ? activity.fraction : nil,
                                             tone: activity.progressTone,
                                             height: StudioLinearProgress.thinHeight)
                            .frame(maxWidth: 140)
                        Text(SFTPEntryActivityText.line(activity))
                            .studioFont(.caption.weight(600))
                            .foregroundStyle(activity.studioTone.foreground)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(entry.isDirectory ? "—" : entry.size.byteString)
                .studioFont(.mono)
                .foregroundStyle(Studio.Palette.ink2)
                .frame(width: Self.sizeWidth, alignment: .trailing)
            Text(entry.modified.map { $0.formatted(.dateTime.year().month().day()) } ?? "—")
                .studioFont(.small)
                .foregroundStyle(Studio.Palette.ink2)
                .lineLimit(1)
                .frame(width: Self.dateWidth, alignment: .trailing)
        }
        .padding(.horizontal, Studio.Space.ml)
        .padding(.vertical, 7)
        .frame(minHeight: 38)
        .background(highlight)
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: Studio.Radius.small, style: .continuous)
                    .strokeBorder(Studio.Palette.accent, lineWidth: 2)
                    .padding(2)
            }
        }
    }

    private var highlight: Color {
        if isDropTarget || isSelected { return Studio.Palette.accentSoft }
        if isHovered { return Studio.Palette.segment }
        return .clear
    }
}

/// The list's sortable column titles, pinned above the rows.
struct SFTPColumnHeader: View {
    let sortKey: SFTPBrowserSortKey
    let ascending: Bool
    let onSort: (SFTPBrowserSortKey) -> Void

    var body: some View {
        HStack(spacing: Studio.Space.m) {
            Color.clear.frame(width: StudioArtSize.xs.side, height: 1)
            column(.name).frame(maxWidth: .infinity, alignment: .leading)
            column(.size).frame(width: SFTPEntryRow.sizeWidth, alignment: .trailing)
            column(.modified).frame(width: SFTPEntryRow.dateWidth, alignment: .trailing)
        }
        .padding(.horizontal, Studio.Space.ml)
        .frame(height: 34)
        .background(Studio.Palette.card)
        .overlay(alignment: .bottom) { StudioDivider() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("Sort by column"))
    }

    private func column(_ key: SFTPBrowserSortKey) -> some View {
        let active = sortKey == key
        return Button { onSort(key) } label: {
            HStack(spacing: 3) {
                Text(key.title)
                if active {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down")
                        .font(StudioFonts.font(.ui, size: 8, weight: 800))
                }
            }
            .studioFont(.eyebrow)
            .foregroundStyle(active ? Studio.Palette.ink : Studio.Palette.ink3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(active
            ? L10n.t("%1$@, sorted %2$@", key.title, ascending ? L10n.t("ascending") : L10n.t("descending"))
            : L10n.t("Sort by %@", key.title))
        .accessibilityHint(active ? L10n.t("Activate to reverse the order.")
                                  : L10n.t("Activate to sort by this column."))
    }
}

/// One remote item as a grid tile (the mockup's server board): artwork, name, a size and date
/// line, and a progress ring when the item is being transferred.
struct SFTPEntryTile: View {
    let entry: SFTPEntry
    let isSelected: Bool
    let isHovered: Bool
    let isDropTarget: Bool
    var activity: SFTPTransfer?

    var body: some View {
        VStack(alignment: .leading, spacing: Studio.Space.sm) {
            HStack(alignment: .top) {
                SFTPEntryArtwork(entry: entry, size: .m)
                Spacer(minLength: Studio.Space.xs)
                if let activity {
                    StudioProgressArc(fraction: activity.total > 0 ? activity.fraction : nil,
                                      tone: activity.progressTone, diameter: 32,
                                      accessibilityLabel: L10n.t("Transfer progress"))
                }
            }
            FileNameText(entry.name, lineLimit: 1)
                .studioFont(.small.weight(700))
                .foregroundStyle(Studio.Palette.ink)
            Text(detail)
                .studioFont(activity == nil ? .tiny : .tiny.weight(650))
                .foregroundStyle(activity?.studioTone.foreground ?? Studio.Palette.ink3)
                .lineLimit(1)
        }
        .padding(Studio.Space.ml)
        .frame(maxWidth: .infinity, alignment: .leading)
        .studioSurface(.card, radius: Studio.Radius.card,
                       elevation: isHovered ? .floating : .card,
                       isSelected: isSelected || isDropTarget)
        .background {
            if isDropTarget {
                RoundedRectangle(cornerRadius: Studio.Radius.card, style: .continuous)
                    .fill(Studio.Palette.accentSoft)
                    .padding(-4)
            }
        }
    }

    private var detail: String {
        if let activity { return SFTPEntryActivityText.line(activity) }
        let date = entry.modified.map { $0.formatted(.dateTime.day().month(.abbreviated)) }
        if entry.isDirectory { return date ?? L10n.t("Folder") }
        return [entry.size.byteString, date].compactMap { $0 }.joined(separator: " · ")
    }
}

/// "Downloading · 78%", "Paused · 34%", "Uploading · 2.1 GB".
enum SFTPEntryActivityText {
    static func line(_ transfer: SFTPTransfer) -> String {
        L10n.t("%1$@ · %2$@", transfer.stateLabel, transfer.progressLabel)
    }
}
