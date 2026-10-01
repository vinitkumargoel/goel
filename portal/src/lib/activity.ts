import { fmtSpeed } from './format'
import type { StatusToken, TaskRow } from './types'

/** Moving bytes now: what the tab title and favicon ring summarise. */
const RUNNING: ReadonlySet<StatusToken> = new Set<StatusToken>(['downloading', 'metadata', 'verifying'])

export interface Activity {
  active: number
  /** 0–1 over the running downloads whose size is known; null when none has one. */
  progress: number | null
  down: number
  failed: number
}

export function summarise(tasks: readonly TaskRow[]): Activity {
  let active = 0
  let done = 0
  let total = 0
  let down = 0
  let failed = 0
  for (const t of tasks) {
    if (t.statusToken === 'failed') failed++
    if (!RUNNING.has(t.statusToken)) continue
    active++
    down += t.downSpeed || 0
    if (t.totalBytes != null && t.totalBytes > 0) {
      total += t.totalBytes
      done += Math.min(t.doneBytes, t.totalBytes)
    }
  }
  return { active, progress: total > 0 ? done / total : null, down, failed }
}

export const APP_TITLE = 'Goel°'

/** "↓ 42 MB/s · 62% · 3 active — Goel°" while working; just "Goel°" when idle. */
export function documentTitle(a: Activity, activeLabel: (count: number) => string): string {
  if (a.active === 0) return APP_TITLE
  const parts = [`↓ ${fmtSpeed(a.down)}`]
  if (a.progress != null) parts.push(`${Math.floor(a.progress * 100)}%`)
  parts.push(activeLabel(a.active))
  return `${parts.join(' · ')} — ${APP_TITLE}`
}

export interface Transitions {
  finished: TaskRow[]
  failed: TaskRow[]
}

/** A download "finishes" when it reaches completed or seeding from anything else. */
const DONE: ReadonlySet<StatusToken> = new Set<StatusToken>(['completed', 'seeding'])

/**
 * What changed since the last snapshot. The first snapshot (`previous` null) reports nothing:
 * opening the portal must not announce every download that finished last week, and a task
 * seen for the first time already finished is not news either.
 */
export function transitions(
  previous: ReadonlyMap<string, StatusToken> | null,
  next: readonly TaskRow[],
): Transitions {
  const out: Transitions = { finished: [], failed: [] }
  if (previous == null) return out
  for (const t of next) {
    const before = previous.get(t.id)
    if (before == null || before === t.statusToken) continue
    if (DONE.has(t.statusToken) && !DONE.has(before)) out.finished.push(t)
    else if (t.statusToken === 'failed') out.failed.push(t)
  }
  return out
}

export function statusMap(tasks: readonly TaskRow[]): Map<string, StatusToken> {
  return new Map(tasks.map((t) => [t.id, t.statusToken]))
}
