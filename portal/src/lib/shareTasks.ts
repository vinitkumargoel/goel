import type { TaskRow } from './types'

function sameValue(a: unknown, b: unknown): boolean {
  if (Object.is(a, b)) return true
  // `tags` is the one array field (of strings): every JSON parse hands out a fresh one.
  return Array.isArray(a) && Array.isArray(b) && a.length === b.length && a.every((v, i) => Object.is(v, b[i]))
}

/** Every `TaskRow` field is a primitive or a flat array of them, so a shallow compare is a full compare. */
export function sameTask(a: TaskRow, b: TaskRow): boolean {
  if (a === b) return true
  const keys = Object.keys(a) as (keyof TaskRow)[]
  if (keys.length !== Object.keys(b).length) return false
  return keys.every((k) => sameValue(a[k], b[k]))
}

/**
 * Structural sharing for snapshots: each unchanged row keeps its previous object, so a memoised
 * row skips re-rendering, and when nothing changed at all the previous array itself comes back —
 * which lets `setState` bail out of the render entirely.
 */
export function shareTasks(prev: readonly TaskRow[], next: readonly TaskRow[]): TaskRow[] {
  const byId = new Map(prev.map((t) => [t.id, t]))
  let changed = prev.length !== next.length
  const shared = next.map((task, i) => {
    const old = byId.get(task.id)
    const kept = old && sameTask(old, task) ? old : task
    if (kept !== prev[i]) changed = true
    return kept
  })
  return changed ? shared : (prev as TaskRow[])
}
