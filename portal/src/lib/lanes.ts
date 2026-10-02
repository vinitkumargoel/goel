import { groupTasks, type GroupBy, type TaskGroup } from './grouping'
import { byQueuePosition } from './queueControls'
import type { StatusToken, TaskRow } from './types'

/**
 * The Board's four status lanes, mirrored from the app's `BoardLaneKind`
 * (Sources/GoelApp/UI/Downloads/DownloadBoardLanes.swift). Every task lands in exactly one:
 *
 * | Lane        | States                                     |
 * |-------------|--------------------------------------------|
 * | downloading | downloading, verifying, metadata            |
 * | upNext      | queued, in queue order                      |
 * | needsYou    | paused, failed (and, in the app, a missing file — the wire has no such state) |
 * | done        | completed, seeding                          |
 */
export type LaneKind = 'downloading' | 'upNext' | 'needsYou' | 'done'

export const LANE_ORDER: readonly LaneKind[] = ['downloading', 'upNext', 'needsYou', 'done']

const LANE_OF: Readonly<Record<StatusToken, LaneKind>> = {
  downloading: 'downloading',
  verifying: 'downloading',
  metadata: 'downloading',
  queued: 'upNext',
  paused: 'needsYou',
  failed: 'needsYou',
  completed: 'done',
  seeding: 'done',
}

export function laneOf(task: Pick<TaskRow, 'statusToken'>): LaneKind {
  return LANE_OF[task.statusToken]
}

/** The tall card with artwork and an arc while bytes are moving; the compact card otherwise. */
export type CardStyle = 'large' | 'compact'

export function cardStyle(task: Pick<TaskRow, 'statusToken'>): CardStyle {
  return task.statusToken === 'downloading' || task.statusToken === 'verifying' ? 'large' : 'compact'
}

export interface BoardLane {
  /** `lane.<kind>` for a status lane, `group.<by>.<key>` for a Group by lane. */
  id: string
  /** Null for a Group by lane. */
  kind: LaneKind | null
  /** Set for a Group by lane: what the list's section header would say. */
  group: TaskGroup | null
  tasks: TaskRow[]
  /** Status lanes only: the Done lane says "Done today" when every card in it finished today. */
  doneToday: boolean
}

function startOfDay(nowMs: number): number {
  const d = new Date(nowMs)
  d.setHours(0, 0, 0, 0)
  return d.getTime() / 1000
}

/** "Done today" only when it is true of every card; one older finish makes it plain "Done". */
export function allFinishedToday(tasks: readonly TaskRow[], nowMs: number = Date.now()): boolean {
  const start = startOfDay(nowMs)
  return tasks.length > 0 && tasks.every((t) => (t.completedAt ?? 0) >= start)
}

/**
 * The lanes for what the library currently shows, cards in `visible` order. Empty lanes are left
 * out, so the board closes up around them. With a Group by on, the board lanes by those groups
 * instead, in the order the Table's sections use, so Group by means the same in both layouts.
 */
export function boardLanes(
  visible: readonly TaskRow[],
  group: GroupBy,
  nowMs: number = Date.now(),
): BoardLane[] {
  if (group !== 'none') {
    return groupTasks(visible, group, nowMs).map((g) => ({
      id: `group.${g.by}.${g.key}`,
      kind: null,
      group: g,
      tasks: g.tasks,
      doneToday: false,
    }))
  }
  const buckets = new Map<LaneKind, TaskRow[]>()
  for (const task of visible) {
    const kind = laneOf(task)
    const bucket = buckets.get(kind)
    if (bucket) bucket.push(task)
    else buckets.set(kind, [task])
  }
  return LANE_ORDER.flatMap((kind) => {
    const bucket = buckets.get(kind)
    if (!bucket) return []
    const tasks = kind === 'upNext' ? byQueuePosition(bucket) : bucket
    return [
      {
        id: `lane.${kind}`,
        kind,
        group: null,
        tasks,
        doneToday: kind === 'done' && allFinishedToday(tasks, nowMs),
      },
    ]
  })
}

/** The cards in reading order — lane by lane, top to bottom — for arrow keys and Shift-click ranges. */
export function flattenLanes(lanes: readonly BoardLane[]): TaskRow[] {
  return lanes.flatMap((lane) => lane.tasks)
}

/**
 * ← and → on the board: the card at the same height in the neighbouring lane, clamped to that
 * lane's length. With nothing current, → starts at the first lane and ← at the last.
 */
export function laneNeighbor(lanes: readonly BoardLane[], current: string | null, step: 1 | -1): string | null {
  const full = lanes.filter((lane) => lane.tasks.length > 0)
  if (full.length === 0) return null
  const laneIndex = current == null ? -1 : full.findIndex((lane) => lane.tasks.some((t) => t.id === current))
  if (laneIndex < 0) return (step > 0 ? full[0] : full[full.length - 1])?.tasks[0]?.id ?? null
  const position = full[laneIndex]!.tasks.findIndex((t) => t.id === current)
  const target = full[Math.min(Math.max(0, laneIndex + step), full.length - 1)]!
  return target.tasks[Math.min(position, target.tasks.length - 1)]?.id ?? null
}

// Layout, mirrored from the app's DownloadBoardLanes so both boards break into columns alike.

export const LANE_MIN_WIDTH = 236
export const LANE_HEADER_HEIGHT = 30
export const LARGE_CARD_HEIGHT = 170
export const COMPACT_CARD_HEIGHT = 62
export const STACKED_LANE_GAP = 22

/** How many columns fit `width`: never more than there are lanes, never fewer than one. */
export function columnCount(width: number, laneCount: number, gap: number): number {
  if (laneCount <= 0) return 0
  if (!Number.isFinite(width) || width <= 0) return laneCount
  const fit = Math.floor((width + gap) / (LANE_MIN_WIDTH + gap))
  return Math.max(1, Math.min(laneCount, fit))
}

/** A rough height for a lane, used only to balance columns. */
export function estimatedHeight(lane: Pick<BoardLane, 'tasks'>, cardGap: number): number {
  const cards = lane.tasks.reduce((sum, task) => {
    const height = cardStyle(task) === 'large' ? LARGE_CARD_HEIGHT : COMPACT_CARD_HEIGHT
    return sum + height + (task.statusToken === 'failed' ? 30 : 0)
  }, 0)
  return LANE_HEADER_HEIGHT + cards + cardGap * lane.tasks.length
}

/**
 * Splits lanes into `count` columns of consecutive lanes, so the reading order holds, with the
 * tallest column as short as possible. Four status lanes in three columns stack Up next over
 * Needs you, as the app does. Returns lane indices per column.
 */
export function laneColumns(heights: readonly number[], count: number, stackGap = STACKED_LANE_GAP): number[][] {
  const n = heights.length
  if (n === 0) return []
  const k = Math.max(1, Math.min(count, n))
  if (k >= n) return heights.map((_, i) => [i])

  // best[j][i]: the smallest possible tallest column for the first i lanes in j columns.
  const best = Array.from({ length: k + 1 }, () => new Array<number>(n + 1).fill(Infinity))
  const cut = Array.from({ length: k + 1 }, () => new Array<number>(n + 1).fill(0))
  best[0]![0] = 0
  const span = (from: number, to: number) =>
    heights.slice(from, to).reduce((a, b) => a + b, 0) + stackGap * Math.max(0, to - from - 1)
  for (let j = 1; j <= k; j++) {
    for (let i = j; i <= n; i++) {
      for (let start = j - 1; start < i; start++) {
        const prev = best[j - 1]![start]!
        if (prev === Infinity) continue
        const candidate = Math.max(prev, span(start, i))
        if (candidate < best[j]![i]!) {
          best[j]![i] = candidate
          cut[j]![i] = start
        }
      }
    }
  }
  const result: number[][] = []
  let end = n
  for (let j = k; j >= 1; j--) {
    const start = cut[j]![end]!
    result.unshift(Array.from({ length: end - start }, (_, i) => start + i))
    end = start
  }
  return result
}
