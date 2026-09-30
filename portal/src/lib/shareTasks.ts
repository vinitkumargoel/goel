import type { TaskRow } from './types'

/** Every `TaskRow` field is a primitive, so a shallow compare is a full compare. */
export function sameTask(a: TaskRow, b: TaskRow): boolean {
  if (a === b) return true
  const keys = Object.keys(a) as (keyof TaskRow)[]
  if (keys.length !== Object.keys(b).length) return false
  return keys.every((k) => Object.is(a[k], b[k]))
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
