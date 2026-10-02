import SwiftUI
import AppKit
import GoelCore

/// A board card. Large while bytes are moving (artwork band, progress arc, speed and time left),
/// compact otherwise. Like the list's rows it is a value with a non-observed `vm`, so a tick
/// only redraws the cards whose data changed.
struct DownloadBoardCard: DownloadHoverable {
    let task: DownloadTask
    var queueRank: Int?
    let isSelected: Bool
    var isHovered = false
    let speed: SpeedSample
    let summary: DownloadSelectionSummary?
    let context: DownloadItemContext
    let vm: AppViewModel

    @Environment(\.quickLookAction) private var quickLook

    nonisolated static func == (lhs: DownloadBoardCard, rhs: DownloadBoardCard) -> Bool {
        lhs.task == rhs.task
            && lhs.queueRank == rhs.queueRank
            && lhs.isSelected == rhs.isSelected
            && lhs.isHovered == rhs.isHovered
            && lhs.speed == rhs.speed
            && lhs.summary == rhs.summary
            && lhs.context == rhs.context
            && lhs.vm === rhs.vm
    }

    var body: some View {
        let style = BoardCardStyle(task: task)
        let radius = style == .large ? Studio.Radius.boardCard : Studio.Radius.compactCard
        Group {
            if style == .large { large } else { compact }
        }
        .studioSurface(.card, radius: radius, elevation: .card, isSelected: isSelected)
        .overlay {
            if task.status.isFailed && !isSelected {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Studio.Palette.badSoft, lineWidth: 1.5)
                    .allowsHitTesting(false)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .modifier(DownloadItemBehaviour(task: task, layout: .board, isSelected: isSelected, queueRank: queueRank,
                                        summary: summary, context: context, vm: vm, quickLook: quickLook))
    }

    private var kind: StudioArtKind { StudioArtKind(task: task) }

    // MARK: Large (`.dcard`)

    private var large: some View {
        VStack(alignment: .leading, spacing: 0) {
            StudioArtworkBand(kind: kind) {
                if isHovered {
                    DownloadCardHoverBar(task: task, vm: vm)
                } else {
                    StudioKindBadge(kind: task.kind, style: .glass)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(task.compactDisplayName)
                    .studioFont(.cardTitle)
                    .foregroundStyle(Studio.Palette.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Studio.Space.sm)
                    .padding(.trailing, 58)
                Text(DownloadCardText.largeMeta(task))
                    .studioFont(.small)
                    .foregroundStyle(Studio.Palette.ink3)
                    .lineLimit(1)
                    .padding(.trailing, 58)
                stats
                    .padding(.top, Studio.Space.sm)
            }
            .padding(.horizontal, Studio.Space.ml)
            .padding(.bottom, Studio.Space.ml)
        }
        .overlay(alignment: .topTrailing) {
            StudioProgressArc(fraction: task.fractionCompleted, tone: StudioProgressTone(task: task), diameter: 46)
                .padding(3)
                .background(Circle().fill(Studio.Palette.card).studioElevation(.raised))
                .padding(.top, 66 - 24)
                .padding(.trailing, Studio.Space.ml)
                .a11yDecorative()
        }
    }

    /// Speeds and time left; in a narrow lane the upload rate gives way first.
    private var stats: some View {
        ViewThatFits(in: .horizontal) {
            statsRow(showsUpload: true)
            statsRow(showsUpload: false)
        }
        .studioMono()
        .lineLimit(1)
    }

    private func statsRow(showsUpload: Bool) -> some View {
        let text = SpeedCellText(speed: speed, isTorrent: task.kind == .torrent)
        return HStack(spacing: Studio.Space.sm) {
            if let down = text.down {
                Text(down).foregroundStyle(Studio.Palette.accent)
            }
            if showsUpload, let up = text.up {
                Text(up).foregroundStyle(speed.up >= 1 ? Studio.Palette.upload : Studio.Palette.ink3)
            }
            Spacer(minLength: Studio.Space.xs)
            Text(DownloadCardText.largeTrailing(task))
                .foregroundStyle(Studio.Palette.ink2)
        }
    }

    // MARK: Compact (`.mcard`)

    private var compact: some View {
        HStack(spacing: 11) {
            if task.status == .queued, let rank = queueRank {
                Text(verbatim: "#\(rank)")
                    .studioFont(.monoSmall)
                    .foregroundStyle(Studio.Palette.ink3)
                    .frame(minWidth: 18, alignment: .leading)
            }
            StudioFileArtwork(kind: kind, size: .s,
                              isFaded: task.status == .paused || task.isFileMissing,
                              isFetchingMetadata: task.status == .requestingMetadata)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.compactDisplayName)
                    .studioFont(Studio.TextStyle.bodyStrong.weight(650))
                    .foregroundStyle(Studio.Palette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                metaLine
                compactExtra
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            trailingButton
        }
        .padding(.horizontal, Studio.Space.m)
        .padding(.vertical, 11)
    }

    private var metaLine: some View {
        let meta = DownloadCardText.compactMeta(task, speed: speed, queueRank: queueRank)
        return Text(meta.text)
            .studioFont(.caption)
            .foregroundStyle(color(meta.tone))
            .lineLimit(task.status.isFailed ? 2 : 1)
            .truncationMode(.middle)
            .help(task.studioStatusTooltip)
    }

    @ViewBuilder
    private var compactExtra: some View {
        if task.status.isFailed {
            HStack(spacing: Studio.Space.xs) {
                Button(L10n.t("Retry"), systemImage: "arrow.clockwise") { vm.retry(task.id) }
                    .buttonStyle(.studio(.soft, size: .small))
                    .accessibilityLabel(L10n.t("%1$@ %2$@", L10n.t("Retry"), task.name))
                Button(L10n.t("Details")) {
                    vm.selectOnly(task.id)
                    vm.detailPanelVisible = true
                }
                .buttonStyle(.studio(.ghost, size: .small))
            }
            .padding(.top, Studio.Space.xs)
        } else if task.status == .requestingMetadata || task.status == .paused {
            MiniProgressBar(task: task)
                .padding(.top, 5)
        } else if let progress = task.seedTargetProgress {
            ProgressTrack(fraction: progress, tone: .upload)
                .padding(.top, 5)
        }
    }

    /// Resume a paused card, open or show a finished file, locate a missing one; Pause on hover.
    @ViewBuilder
    private var trailingButton: some View {
        if task.status == .completed && !task.isFileMissing {
            if task.isMediaFile {
                StudioIconButton("play.fill", label: L10n.t("Open"), size: .small, bordered: true) { vm.openFile(task) }
            } else {
                StudioIconButton("folder", label: L10n.t("Show in Finder"), size: .small, bordered: true) {
                    vm.revealInFinder(task)
                }
            }
        } else if let action = RowStateAction(task: task), action != .retry,
                  action == .locate || task.status == .paused || isHovered || isSelected {
            StudioIconButton(action.symbol, label: L10n.t("%1$@ %2$@", action.title, task.name), size: .small,
                             bordered: true) {
                action.perform(on: task, vm: vm)
            }
            .help(action.title)
        }
    }

    private func color(_ tone: DownloadCardText.Tone) -> Color {
        switch tone {
        case .plain: return Studio.Palette.ink3
        case .accent: return Studio.Palette.accent
        case .upload: return Studio.Palette.upload
        case .warn: return Studio.Palette.warn
        case .bad: return Studio.Palette.bad
        }
    }
}

/// A plain thin track and fill (no sweep-in), for a seeding card's ratio target.
private struct ProgressTrack: View {
    let fraction: Double
    let tone: StudioProgressTone

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Studio.Palette.track)
                Capsule().fill(tone.color).frame(width: geo.size.width * CGFloat(min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 4)
        .a11yDecorative()
    }
}

/// The glass bar a large card shows on hover (`.hoverbar`): its state action and Show in Finder.
struct DownloadCardHoverBar: View {
    let task: DownloadTask
    let vm: AppViewModel

    var body: some View {
        HStack(spacing: 2) {
            if let action = RowStateAction(task: task) {
                StudioIconButton(action.symbol, label: L10n.t("%1$@ %2$@", action.title, task.name), size: .small) {
                    action.perform(on: task, vm: vm)
                }
                .help(action.title)
            }
            StudioIconButton("folder", label: L10n.t("Show in Finder"), size: .small) { vm.revealInFinder(task) }
        }
        .padding(3)
        .studioGlass(in: RoundedRectangle(cornerRadius: Studio.Radius.control, style: .continuous))
    }
}
