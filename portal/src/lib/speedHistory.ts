import type { TaskRow } from './types'

/** One frame's rates, bytes per second. */
export interface SpeedSample {
  down: number
  up: number
}

/** Samples kept per series: one per snapshot frame, so about a minute at the stream's pace. */
export const HISTORY_LENGTH = 60

export interface SpeedHistory {
  /** Oldest first, at most `HISTORY_LENGTH` per task. Only tasks in the latest frame have a series. */
  perTask: ReadonlyMap<string, readonly SpeedSample[]>
  /** The summed rates of each frame, oldest first. */
  total: readonly SpeedSample[]
}

export const EMPTY_HISTORY: SpeedHistory = { perTask: new Map(), total: [] }

/** A new series with `sample` appended and the oldest dropped past `cap`; the input is not touched. */
export function appendSample(
  series: readonly SpeedSample[],
  sample: SpeedSample,
  cap = HISTORY_LENGTH,
): SpeedSample[] {
  const start = Math.max(0, series.length + 1 - cap)
  return [...series.slice(start), sample]
}

function rate(n: number | null | undefined): number {
  return n != null && isFinite(n) && n > 0 ? n : 0
}

function isIdle(s: SpeedSample | undefined): boolean {
  return s == null || (s.down === 0 && s.up === 0)
}

/**
 * Folds one snapshot frame into the history. Memory stays bounded: each series is capped, a task
 * missing from the frame (removed) loses its series rather than lingering, and only tasks that are
 * moving — or still have a non-zero sample to scroll off — keep one, so a large idle queue costs
 * nothing per tick.
 *
 * An idle frame over an already-idle history returns `history` itself: the caller can skip the
 * write, and nothing subscribed re-renders.
 */
export function recordFrame(
  history: SpeedHistory,
  rows: readonly TaskRow[],
  cap = HISTORY_LENGTH,
): SpeedHistory {
  const samples = rows.map((row) => ({ down: rate(row.downSpeed), up: rate(row.upSpeed) }))
  const allIdle = samples.every(isIdle)
  if (allIdle && history.total.length > 0 && isIdle(history.total.at(-1))) {
    const present = new Set(rows.map((row) => row.id))
    if ([...history.perTask.keys()].every((id) => present.has(id))) return history
  }

  const perTask = new Map<string, readonly SpeedSample[]>()
  let down = 0
  let up = 0
  rows.forEach((row, i) => {
    const sample = samples[i]!
    down += sample.down
    up += sample.up
    const prev = history.perTask.get(row.id)
    if (isIdle(sample) && (prev == null || prev.every(isIdle))) return
    perTask.set(row.id, appendSample(prev ?? [], sample, cap))
  })
  return { perTask, total: appendSample(history.total, { down, up }, cap) }
}

/** The highest rate in either direction; the chart's vertical scale. */
export function peakRate(series: readonly SpeedSample[]): number {
  return series.reduce((max, s) => Math.max(max, s.down, s.up), 0)
}

/**
 * SVG path data for a series on a `width` × `height` box, right-aligned so the newest sample sits
 * at the right edge whatever the buffer's fill. `area` closes the path along the baseline.
 */
export function seriesPath(
  values: readonly number[],
  width: number,
  height: number,
  peak: number,
  area: boolean,
  slots = HISTORY_LENGTH,
): string {
  if (values.length === 0) return ''
  const step = width / Math.max(1, slots - 1)
  const scale = peak > 0 ? height / peak : 0
  const x0 = width - (values.length - 1) * step
  const pts = values.map((v, i) => {
    const x = x0 + i * step
    const y = height - Math.min(v, peak) * scale
    return `${round(x)},${round(y)}`
  })
  const line = `M${pts.join('L')}`
  return area ? `${line}L${round(width)},${height}L${round(x0)},${height}Z` : line
}

function round(n: number): number {
  return Math.round(n * 10) / 10
}
