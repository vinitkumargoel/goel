import type { StatusToken, TaskRow } from './types'

export type SortKey = 'name' | 'size' | 'status' | 'speed'
export type SortDir = 'asc' | 'desc'

/** `key: null` keeps the server's order, which is the order tasks were added. */
export interface SortState {
  key: SortKey | null
  dir: SortDir
}

export const UNSORTED: SortState = { key: null, dir: 'asc' }

/** Work in flight first, finished last — the order a user scanning the queue cares about. */
const STATUS_RANK: Record<StatusToken, number> = {
  downloading: 0,
  metadata: 1,
  verifying: 2,
  queued: 3,
  paused: 4,
  failed: 5,
  seeding: 6,
  completed: 7,
}

const collator = new Intl.Collator(undefined, { numeric: true, sensitivity: 'base' })

function compare(a: TaskRow, b: TaskRow, key: SortKey): number {
  switch (key) {
    case 'name':
      return collator.compare(a.name, b.name)
    case 'size':
      // Unknown sizes sort as smallest, so they gather at one end rather than scatter.
      return (a.totalBytes ?? -1) - (b.totalBytes ?? -1)
    case 'status':
      return STATUS_RANK[a.statusToken] - STATUS_RANK[b.statusToken]
    case 'speed':
      return (a.downSpeed || 0) - (b.downSpeed || 0)
  }
}

/** Returns a new array; ties keep their incoming order, since `Array.prototype.sort` is stable. */
export function sortTasks(tasks: readonly TaskRow[], sort: SortState): TaskRow[] {
  const { key, dir } = sort
  if (key === null) return [...tasks]
  const sign = dir === 'asc' ? 1 : -1
  return [...tasks].sort((a, b) => sign * compare(a, b, key))
}

/** Clicking a header sorts by it ascending; clicking the active header flips the direction. */
export function nextSort(current: SortState, key: SortKey): SortState {
  if (current.key !== key) return { key, dir: 'asc' }
  return { key, dir: current.dir === 'asc' ? 'desc' : 'asc' }
}

export function ariaSort(sort: SortState, key: SortKey): 'ascending' | 'descending' | 'none' {
  if (sort.key !== key) return 'none'
  return sort.dir === 'asc' ? 'ascending' : 'descending'
}
