import SwiftUI
import GoelCore

/// The Board: lanes of cards (Downloading · Up next · Needs you · Done), or one lane per group
/// while a Group by is on. Lanes fill as many columns as the width allows; when there are more
/// lanes than columns, consecutive lanes stack in a column (Up next over Needs you, as the
/// mockup does), balanced so no column runs much longer than the rest. Empty lanes are left out.
struct DownloadBoardView: View {
    @EnvironmentObject private var vm: AppViewModel
    @EnvironmentObject private var telemetry: TelemetryStore
    let inputs: DownloadItemInputs

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var width: CGFloat = 0

    var body: some View {
        let lanes = vm.boardLanes
        let gap = Studio.Space.laneGap
        let count = BoardLanes.columnCount(width: width, laneCount: lanes.count, gap: gap)
        let heights = lanes.map { BoardLanes.estimatedHeight($0, cardGap: Studio.Space.cardGap) }
        let columns = BoardLanes.columns(heights: heights, count: count)
        let laneWidth = count > 0
            ? min(BoardLanes.maximumLaneWidth, max(160, (width - gap * CGFloat(count - 1)) / CGFloat(count)))
            : BoardLanes.minimumLaneWidth
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                HStack(alignment: .top, spacing: gap) {
                    // Keyed by lane id, not position: a lane appearing or emptying must not hand
                    // its neighbour's identity (hover, scroll anchors, transitions) to another lane.
                    ForEach(BoardColumn.make(lanes: lanes, columns: columns)) { column in
                        VStack(alignment: .leading, spacing: BoardLanes.stackedLaneGap) {
                            ForEach(column.lanes) { lane in
                                laneView(lane)
                            }
                            if column.isLast, vm.grouping == .none {
                                DownloadQueueSummaryCard()
                            }
                        }
                        .frame(width: width > 0 ? laneWidth : nil, alignment: .top)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, Studio.Space.gutter)
                .padding(.top, Studio.Space.xs)
                .padding(.bottom, Studio.Space.xxl)
                .contentShape(Rectangle())
                .onTapGesture { vm.selectNone() }
            }
            .onGeometryChange(for: CGFloat.self) { ($0.size.width - 2 * Studio.Space.gutter).rounded() } action: {
                width = $0
            }
            .onChange(of: vm.selectedTask?.id) { _, id in
                guard let id else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    private func laneView(_ lane: BoardLane) -> some View {
        LazyVStack(alignment: .leading, spacing: Studio.Space.cardGap) {
            StudioLaneHeader(title: lane.title, count: lane.tasks.count,
                             detail: detail(for: lane), detailIsMono: lane.kind == .downloading || lane.kind == nil)
            ForEach(lane.tasks) { task in
                HoverTracking(content: card(task))
                    .id(task.id)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(lane.title)
    }

    private func card(_ task: DownloadTask) -> DownloadBoardCard {
        let isSelected = vm.isSelected(task.id)
        return DownloadBoardCard(
            task: task,
            queueRank: inputs.ranks[task.id],
            isSelected: isSelected,
            speed: telemetry.displaySpeed(for: task),
            summary: isSelected ? inputs.summary : nil,
            context: inputs.context,
            vm: vm)
    }

    private func detail(for lane: BoardLane) -> String? {
        switch lane.kind {
        case .downloading:
            let down = lane.tasks.reduce(0) { $0 + telemetry.displaySpeed(for: $1).down }
            return down >= 1 ? "↓ " + down.speedString : nil
        case .upNext:
            return L10n.t("starts in order")
        case .needsYou, .done:
            return nil
        case nil:
            return lane.totalBytes > 0 ? lane.totalBytes.byteString : nil
        }
    }
}

/// What every row or card of one pass shares, worked out once per body instead of per item.
struct DownloadItemInputs {
    let context: DownloadItemContext
    let summary: DownloadSelectionSummary
    let ranks: [DownloadTask.ID: Int]
    let focused: Bool

    @MainActor
    init(vm: AppViewModel, focused: Bool) {
        context = DownloadItemContext(vm: vm)
        summary = DownloadSelectionSummary(vm.selection.count > 1 ? vm.selectedTasks : [])
        ranks = vm.queueRanks
        self.focused = focused
    }
}

/// The board's queue card (bottom of the last column): what is left, when it should be done,
/// and the last minute of throughput.
struct DownloadQueueSummaryCard: View {
    @EnvironmentObject private var vm: AppViewModel
    @EnvironmentObject private var telemetry: TelemetryStore

    var body: some View {
        let overview = vm.queueOverview
        if overview.remainingBytes > 0 {
            let history = telemetry.recentGlobalHistory(60)
            VStack(alignment: .leading, spacing: Studio.Space.sm) {
                HStack {
                    Text(L10n.t("Queue")).studioFont(.eyebrow).foregroundStyle(Studio.Palette.ink3)
                    Spacer()
                    Text(L10n.t("last 60 s")).studioFont(.monoSmall).foregroundStyle(Studio.Palette.ink3)
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: Studio.Space.xs) {
                        remaining(overview)
                        detail(overview)
                    }
                    VStack(alignment: .leading, spacing: Studio.Space.hair) {
                        remaining(overview)
                        detail(overview)
                    }
                }
                if history.count > 1 {
                    StudioSparkline(values: history.map(\.down))
                        .frame(height: 44)
                }
            }
            .padding(Studio.Space.l)
            .studioSurface(.well, radius: Studio.Radius.card, elevation: .card)
            .padding(.top, Studio.Space.xs)
            .accessibilityElement(children: .combine)
        }
    }

    private func remaining(_ overview: QueueOverview) -> some View {
        Text(overview.remainingBytes.byteString)
            .studioFont(.display, size: 28, weight: 700, tabularNumbers: true)
            .foregroundStyle(Studio.Palette.ink)
            .lineLimit(1)
            .fixedSize()
    }

    private func detail(_ overview: QueueOverview) -> some View {
        Text([L10n.t("left"), overview.doneText()].compactMap { $0 }.joined(separator: " · "))
            .studioFont(.small)
            .foregroundStyle(Studio.Palette.ink2)
            .lineLimit(1)
            .fixedSize()
    }
}
