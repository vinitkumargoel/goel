import { dateGroup, DATE_GROUPS } from './historyTools'
import { sourceHost } from './search'
import type { StatusToken, TaskRow } from './types'

export type GroupBy = 'none' | 'status' | 'added' | 'host'
export const GROUP_BYS: readonly GroupBy[] = ['none', 'status', 'added', 'host']

export interface TaskGroup {
  by: Exclude<GroupBy, 'none'>
  /** A status token, a date bucket, or a host ('' for sources without one). */
  key: string
  tasks: TaskRow[]
}

const STATUS_ORDER: readonly StatusToken[] = [
  'downloading',
  'metadata',
  'verifying',
  'queued',
  'paused',
  'failed',
  'seeding',
  'completed',
]

/**
 * Sections for the library, rows kept in their sorted order within each. Status and date follow a
 * fixed order; hosts are alphabetical, with host-less sources (magnets) last. Empty groups are left out.
 */
export function groupTasks(tasks: readonly TaskRow[], by: GroupBy, nowMs: number = Date.now()): TaskGroup[] {
  if (by === 'none') return []
  const keyOf =
    by === 'status'
      ? (t: TaskRow) => t.statusToken
      : by === 'added'
        ? (t: TaskRow) => dateGroup(t.addedAt, nowMs)
        : (t: TaskRow) => sourceHost(t.source)
  const buckets = new Map<string, TaskRow[]>()
  for (const task of tasks) {
    const key = keyOf(task)
    const bucket = buckets.get(key)
    if (bucket) bucket.push(task)
    else buckets.set(key, [task])
  }
  const order: readonly string[] =
    by === 'status'
      ? STATUS_ORDER
      : by === 'added'
        ? DATE_GROUPS
        : [...buckets.keys()].sort((a, b) => (a === '' ? 1 : b === '' ? -1 : a.localeCompare(b)))
  return order.flatMap((key) => {
    const bucket = buckets.get(key)
    return bucket ? [{ by, key, tasks: bucket }] : []
  })
}
