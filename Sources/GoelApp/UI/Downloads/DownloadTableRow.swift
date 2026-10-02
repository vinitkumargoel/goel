import SwiftUI
import AppKit
import GoelCore

/// One row of the List layout.
///
/// `vm` is deliberately non-observed: observing it rebuilds every row on every task's progress
/// tick. Everything the body reads is a value compared in `==`, and `vm` is used only inside
/// actions, so `.equatable()` skips the rows whose data didn't change on a telemetry tick.
struct DownloadTableRow: DownloadHoverable {
    let task: DownloadTask
    let displayIndex: Int
    /// The row's place in the queue, which "#" shows whatever the sort.
    var queueRank: Int?
    /// The list is in queue order, so hovering "#" offers a drag grip.
    var reorderable = false
    let isSelected: Bool
    /// Selection is dimmer while focus is elsewhere (the omnibox), so it's clear where arrows go.
    let listFocused: Bool
    var isHovered = false
    let speed: SpeedSample
    /// Non-nil only for a selected row; `count > 1` means the context menu acts on the selection.
    let summary: DownloadSelectionSummary?
    let context: DownloadItemContext
    let columns: DownloadColumns
    let vm: AppViewModel

    @Environment(\.quickLookAction) private var quickLook

    nonisolated static func == (lhs: DownloadTableRow, rhs: DownloadTableRow) -> Bool {
        lhs.task == rhs.task
            && lhs.displayIndex == rhs.displayIndex
            && lhs.queueRank == rhs.queueRank
            && lhs.reorderable == rhs.reorderable
            && lhs.isSelected == rhs.isSelected
            && lhs.listFocused == rhs.listFocused
            && lhs.isHovered == rhs.isHovered
            && lhs.speed == rhs.speed
            && lhs.summary == rhs.summary
            && lhs.context == rhs.context
            && lhs.columns == rhs.columns
            && lhs.vm === rhs.vm
    }

    private var isCompact: Bool { columns.density == .compact }

    var body: some View {
        cells
            .padding(.horizontal, 12)
            .padding(.vertical, isCompact ? 3 : 7)
            .frame(minHeight: columns.density.rowHeight)
            .background(rowBackground)
            .contentShape(Rectangle())
            .modifier(DownloadItemBehaviour(task: task, layout: .list, isSelected: isSelected, queueRank: queueRank,
                                            summary: summary, context: context, vm: vm, quickLook: quickLook))
    }

    private var cells: some View {
        HStack(spacing: 0) {
            DownloadIndexCell(task: task, displayIndex: displayIndex, queueRank: queueRank,
                              showsGrip: reorderable && isHovered, vm: vm)
                .frame(width: columns.index)
                .padding(.horizontal, 6)

            nameCell
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 6)

            if columns.showsSize {
                sizeCell
                    .frame(width: columns.size, alignment: .trailing)
                    .padding(.horizontal, 6)
            }
            if columns.showsStatus {
                DownloadStatusCell(task: task, speed: speed, queueRank: queueRank,
                                   foldsSpeed: !columns.showsSpeed, showsReason: isCompact)
                    .help(task.studioStatusTooltip)
                    .frame(width: columns.status, alignment: .leading)
                    .padding(.horizontal, 6)
            }
            if columns.showsAdded {
                Text(task.addedColumnString)
                    .studioFont(.small)
                    .foregroundStyle(Studio.Palette.ink2)
                    .lineLimit(1)
                    .help(task.addedString)
                    .frame(width: columns.added, alignment: .trailing)
                    .padding(.horizontal, 6)
            }
            ForEach(columns.extras) { extra in
                ExtraColumnCell(column: extra, task: task)
                    .frame(width: columns.width(of: extra), alignment: extra.cellAlignment)
                    .padding(.horizontal, 6)
            }
            if columns.showsSpeed {
                DownloadSpeedCell(task: task, speed: speed)
                    .frame(width: columns.speed, alignment: .trailing)
                    .padding(.horizontal, 6)
            }
        }
    }

    private var sizeCell: some View {
        Text(task.totalBytes?.byteString ?? "—")
            .studioFont(.monoBody)
            .foregroundStyle(task.totalBytes == nil ? Studio.Palette.ink3 : Studio.Palette.ink2)
            .lineLimit(1)
    }

    private var rowBackground: some View {
        let shape = RoundedRectangle(cornerRadius: Studio.Radius.control, style: .continuous)
        let fill: Color
        if isSelected {
            fill = listFocused ? Studio.Palette.accentSoft : Studio.Palette.segment
        } else if isHovered {
            fill = Studio.Palette.well
        } else {
            fill = .clear
        }
        return shape.fill(fill)
    }

    // MARK: Name

    @ViewBuilder
    private var nameCell: some View {
        if isCompact { compactNameCell } else { regularNameCell }
    }

    /// Resume, Retry and Locate always show; Pause only for the hovered or selected row.
    private var showsStateButton: Bool {
        guard let action = RowStateAction(task: task) else { return false }
        return action.wantsAttention || isHovered || isSelected
    }

    private var artwork: StudioFileArtwork {
        StudioFileArtwork(kind: StudioArtKind(task: task), size: isCompact ? .xs : .s,
                          isFaded: task.status == .paused || task.isFileMissing,
                          isFetchingMetadata: task.status == .requestingMetadata)
    }

    /// One line: artwork, name, then a thin inline bar in the space left over.
    private var compactNameCell: some View {
        HStack(spacing: Studio.Space.s) {
            artwork
            FileNameText(task.compactDisplayName, lineLimit: 1)
                .studioFont(Studio.TextStyle.callout.weight(650))
                .foregroundStyle(Studio.Palette.ink)
                .layoutPriority(1)
            MiniProgressBar(task: task, height: 3)
                .frame(minWidth: 40, maxWidth: 160)
            Spacer(minLength: 0)
            if showsStateButton { StateButton(task: task, vm: vm, compact: true) }
        }
    }

    private var regularNameCell: some View {
        HStack(spacing: Studio.Space.sm) {
            artwork
            VStack(alignment: .leading, spacing: Studio.Space.xxs) {
                HStack(spacing: 7) {
                    FileNameText(task.compactDisplayName, lineLimit: 1)
                        .studioFont(Studio.TextStyle.bodyStrong.weight(650))
                        .foregroundStyle(Studio.Palette.ink)
                    KindBadge(task: task)
                }
                nameSubline
                if !columns.showsSize, !task.compactSizeLine.isEmpty {
                    Text(task.compactSizeLine)
                        .studioFont(.monoSmall)
                        .foregroundStyle(Studio.Palette.ink3)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if showsStateButton { StateButton(task: task, vm: vm) }
        }
    }

    /// Under the name: the bar, or what replaces it — a failure's reason, two lines deep, or
    /// where a missing file used to be.
    @ViewBuilder
    private var nameSubline: some View {
        if let reason = task.failureMessage {
            Text(reason)
                .studioFont(.tiny)
                .foregroundStyle(Studio.Palette.bad)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 360, alignment: .leading)
        } else if task.isFileMissing {
            Text(L10n.t("Was in %@", (task.saveDirectory as NSString).abbreviatingWithTildeInPath))
                .studioFont(.tiny)
                .foregroundStyle(Studio.Palette.ink3)
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            MiniProgressBar(task: task)
                .frame(maxWidth: 260)
        }
    }
}

/// "#" is the queue place. While the list is in queue order, hovering swaps it for a grip that
/// drags the row (or the selection it belongs to) to a new place.
struct DownloadIndexCell: View {
    let task: DownloadTask
    let displayIndex: Int
    let queueRank: Int?
    let showsGrip: Bool
    let vm: AppViewModel

    var body: some View {
        if showsGrip {
            Image(systemName: "line.3.horizontal")
                .font(StudioFonts.font(.ui, size: 12, weight: 650))
                .foregroundStyle(Studio.Palette.ink3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .help(L10n.t("Drag to reorder the queue"))
                .onDrag {
                    let ids = vm.beginQueueDrag(from: task.id)
                    return NSItemProvider(object: ids.map(\.uuidString).joined(separator: "\n") as NSString)
                }
                .a11yDecorative()
        } else {
            Text(verbatim: "\(queueRank ?? displayIndex)")
                .studioFont(.monoSmall)
                .foregroundStyle(Studio.Palette.ink3)
        }
    }
}
