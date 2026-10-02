import Foundation
import CoreGraphics
import GoelCore

/// Board or List, remembered across launches.
enum DownloadsLayout: String, CaseIterable, Identifiable, Sendable {
    case board, list

    static let storageKey = "downloads.layout"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .board: return L10n.t("Board")
        case .list: return L10n.t("List")
        }
    }

    var symbol: String { self == .board ? "rectangle.3.group" : "list.bullet" }
}

/// The four status lanes of the board. Every task lands in exactly one:
///
/// | Lane         | States                                                   |
/// |--------------|----------------------------------------------------------|
/// | Downloading  | downloading, verifying, requesting metadata              |
/// | Up next      | queued (ordered by queue place)                          |
/// | Needs you    | failed, paused, a finished file that has gone missing    |
/// | Done         | completed, seeding                                       |
///
/// With a Group by active the board lanes by those groups instead (see ``BoardLanes/make``):
/// one lane per section, in the section order the list uses, so Group by means the same in
/// both layouts and the rail, chips and menus never disagree.
enum BoardLaneKind: String, CaseIterable, Hashable, Sendable {
    case downloading, upNext, needsYou, done

    init(task: DownloadTask) {
        if task.isFileMissing { self = .needsYou; return }
        switch task.status {
        case .downloading, .verifying, .requestingMetadata: self = .downloading
        case .queued: self = .upNext
        case .paused, .failed: self = .needsYou
        case .completed, .seeding: self = .done
        }
    }
}

/// How a card is drawn: the tall artwork card with an arc while bytes are moving, the compact
/// one-line card for everything else (the mockup's `.dcard` and `.mcard`).
enum BoardCardStyle: Equatable, Sendable {
    case large, compact

    init(task: DownloadTask) {
        switch task.status {
        case .downloading, .verifying: self = .large
        default: self = .compact
        }
    }
}

/// One lane of cards.
struct BoardLane: Identifiable, Equatable {
    let id: String
    let title: String
    /// Nil for a Group by lane.
    let kind: BoardLaneKind?
    let tasks: [DownloadTask]
    /// The group's total size, shown in a Group by lane's header.
    var totalBytes: Int64 { tasks.reduce(0) { $0 + ($1.totalBytes ?? 0) } }
    /// "Retry All" on a "Needs you" lane that holds a failure; nil elsewhere.
    var retryAllTitle: String? {
        kind == .needsYou && tasks.contains { $0.status.isFailed } ? L10n.t("Retry All") : nil
    }
}

/// One column of stacked lanes, identified by its first lane so SwiftUI keeps identity by lane.
struct BoardColumn: Identifiable, Equatable {
    let id: String
    let lanes: [BoardLane]
    let isLast: Bool

    /// `columns` holds lane indices as ``BoardLanes/columns(heights:count:stackGap:)`` returns them.
    static func make(lanes: [BoardLane], columns: [[Int]]) -> [BoardColumn] {
        columns.enumerated().compactMap { offset, indices in
            let members = indices.filter(lanes.indices.contains).map { lanes[$0] }
            guard let first = members.first else { return nil }
            return BoardColumn(id: first.id, lanes: members, isLast: offset == columns.count - 1)
        }
    }
}

enum BoardLanes {

    /// The lanes for what the list currently shows. Empty lanes are left out, so the board
    /// collapses around them instead of drawing empty columns.
    static func make(visible: [DownloadTask], sections: [ListSection], grouping: ListGrouping,
                     ranks: [DownloadTask.ID: Int], now: Date = Date(),
                     calendar: Calendar = .current) -> [BoardLane] {
        if grouping != .none {
            return sections.filter { !$0.tasks.isEmpty }.map {
                BoardLane(id: "group.\($0.id)", title: $0.title, kind: nil, tasks: $0.tasks)
            }
        }
        return statusLanes(visible, ranks: ranks, now: now, calendar: calendar)
    }

    static func statusLanes(_ visible: [DownloadTask], ranks: [DownloadTask.ID: Int],
                            now: Date = Date(), calendar: Calendar = .current) -> [BoardLane] {
        let grouped = Dictionary(grouping: visible, by: BoardLaneKind.init(task:))
        return BoardLaneKind.allCases.compactMap { kind in
            guard var tasks = grouped[kind], !tasks.isEmpty else { return nil }
            if kind == .upNext { tasks = queueOrdered(tasks, ranks: ranks) }
            return BoardLane(id: "lane.\(kind.rawValue)",
                             title: title(kind, tasks: tasks, now: now, calendar: calendar),
                             kind: kind, tasks: tasks)
        }
    }

    /// "Up next" reads in the order the queue will start them; unranked rows keep their place at the end.
    static func queueOrdered(_ tasks: [DownloadTask], ranks: [DownloadTask.ID: Int]) -> [DownloadTask] {
        tasks.enumerated()
            .sorted { lhs, rhs in
                let l = ranks[lhs.element.id] ?? .max, r = ranks[rhs.element.id] ?? .max
                return l == r ? lhs.offset < rhs.offset : l < r
            }
            .map(\.element)
    }

    static func title(_ kind: BoardLaneKind, tasks: [DownloadTask], now: Date = Date(),
                      calendar: Calendar = .current) -> String {
        switch kind {
        case .downloading: return L10n.t("Downloading")
        case .upNext: return L10n.t("Up next")
        case .needsYou: return L10n.t("Needs you")
        case .done:
            return allFinishedToday(tasks, now: now, calendar: calendar) ? L10n.t("Done today") : L10n.t("Done")
        }
    }

    /// "Done today" only when it is true of every card; an older finish makes it plain "Done".
    static func allFinishedToday(_ tasks: [DownloadTask], now: Date, calendar: Calendar) -> Bool {
        let start = calendar.startOfDay(for: now)
        return !tasks.isEmpty && tasks.allSatisfy { ($0.completedAt ?? .distantPast) >= start }
    }

    /// The cards in reading order: lane by lane, top to bottom. Arrow keys and ⇧-click ranges
    /// walk this order on the board.
    static func flattened(_ lanes: [BoardLane]) -> [DownloadTask] {
        lanes.flatMap(\.tasks)
    }

    // MARK: - Layout

    static let minimumLaneWidth: CGFloat = 236
    static let maximumLaneWidth: CGFloat = 320
    static let laneHeaderHeight: CGFloat = 30
    static let largeCardHeight: CGFloat = 170
    static let compactCardHeight: CGFloat = 62
    static let stackedLaneGap: CGFloat = 22

    /// How many columns fit `width`: never more than there are lanes.
    static func columnCount(width: CGFloat, laneCount: Int, gap: CGFloat) -> Int {
        guard laneCount > 0 else { return 0 }
        guard width.isFinite, width > 0 else { return laneCount }
        let fit = Int(((width + gap) / (minimumLaneWidth + gap)).rounded(.down))
        return max(1, min(laneCount, fit))
    }

    /// A rough height for a lane, used only to balance columns.
    static func estimatedHeight(_ lane: BoardLane, cardGap: CGFloat) -> CGFloat {
        let cards = lane.tasks.reduce(CGFloat(0)) { sum, task in
            var height = BoardCardStyle(task: task) == .large ? largeCardHeight : compactCardHeight
            if task.status.isFailed { height += 30 }
            return sum + height
        }
        return laneHeaderHeight + cards + cardGap * CGFloat(lane.tasks.count)
    }

    /// Splits lanes into `count` columns of consecutive lanes, so the reading order holds, with
    /// the tallest column as short as possible. Four status lanes in three columns stack
    /// Up next over Needs you, as the mockup does.
    static func columns(heights: [CGFloat], count: Int, stackGap: CGFloat = stackedLaneGap) -> [[Int]] {
        let n = heights.count
        guard n > 0 else { return [] }
        let k = max(1, min(count, n))
        guard k < n else { return heights.indices.map { [$0] } }

        // best[j][i]: the smallest possible tallest column for the first i lanes in j columns.
        let infinity = CGFloat.greatestFiniteMagnitude
        var best = Array(repeating: Array(repeating: infinity, count: n + 1), count: k + 1)
        var cut = Array(repeating: Array(repeating: 0, count: n + 1), count: k + 1)
        best[0][0] = 0
        func span(_ from: Int, _ to: Int) -> CGFloat {
            heights[from..<to].reduce(0, +) + stackGap * CGFloat(max(0, to - from - 1))
        }
        for j in 1...k {
            for i in j...n {
                for start in (j - 1)..<i where best[j - 1][start] < infinity {
                    let candidate = max(best[j - 1][start], span(start, i))
                    if candidate < best[j][i] {
                        best[j][i] = candidate
                        cut[j][i] = start
                    }
                }
            }
        }
        var result: [[Int]] = []
        var end = n
        for j in stride(from: k, through: 1, by: -1) {
            let start = cut[j][end]
            result.insert(Array(start..<end), at: 0)
            end = start
        }
        return result
    }

    // MARK: - Keyboard

    /// ← and → on the board: the card at the same height in the neighbouring lane.
    static func laneNeighbor(in lanes: [BoardLane], from current: DownloadTask.ID?, step: Int) -> DownloadTask.ID? {
        let nonEmpty = lanes.filter { !$0.tasks.isEmpty }
        guard !nonEmpty.isEmpty else { return nil }
        guard let current,
              let laneIndex = nonEmpty.firstIndex(where: { $0.tasks.contains { $0.id == current } }),
              let position = nonEmpty[laneIndex].tasks.firstIndex(where: { $0.id == current }) else {
            return step > 0 ? nonEmpty.first?.tasks.first?.id : nonEmpty.last?.tasks.first?.id
        }
        let target = min(max(0, laneIndex + step), nonEmpty.count - 1)
        let tasks = nonEmpty[target].tasks
        return tasks[min(position, tasks.count - 1)].id
    }
}
