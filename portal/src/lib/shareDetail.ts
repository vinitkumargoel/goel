import { sameTask } from './shareTasks'
import type { TaskDetail } from './types'

function same(a: object, b: object): boolean {
  const keys = Object.keys(a) as (keyof typeof a)[]
  return keys.length === Object.keys(b).length && keys.every((k) => Object.is(a[k], b[k]))
}

/** Each unchanged element keeps its previous object; an unchanged array keeps its identity. */
function shareList<T extends object>(prev: readonly T[], next: readonly T[], key?: (item: T) => string | number): readonly T[] {
  const byKey = key ? new Map(prev.map((p) => [key(p), p])) : null
  let changed = prev.length !== next.length
  const shared = next.map((item, i) => {
    const old = byKey ? byKey.get(key!(item)) : prev[i]
    const kept = old && same(old, item) ? old : item
    if (kept !== prev[i]) changed = true
    return kept
  })
  return changed ? shared : prev
}

/**
 * Structural sharing for a refetched detail, as `shareTasks` does for the list: unchanged files,
 * trackers and connections keep their objects, and an unchanged list keeps its array, so the
 * file tree is not rebuilt (nor its rows re-rendered) by a poll that found nothing new.
 */
export function shareDetail(prev: TaskDetail | null, next: TaskDetail): TaskDetail {
  if (!prev || prev.row.id !== next.row.id) return next
  const files = shareList(prev.files, next.files, (f) => f.id) as TaskDetail['files']
  const trackers = shareList(prev.trackers, next.trackers, (t) => t.url) as TaskDetail['trackers']
  const connections = shareList(prev.connections, next.connections, (c) => c.id) as TaskDetail['connections']
  const pieces =
    prev.pieces.length === next.pieces.length && prev.pieces.every((v, i) => v === next.pieces[i])
      ? prev.pieces
      : next.pieces
  const row = sameTask(prev.row, next.row) ? prev.row : next.row
  return { ...next, row, files, trackers, connections, pieces }
}
