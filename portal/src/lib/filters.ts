import { fileType, isActive, type FileType } from './taskKind'
import type { TaskRow } from './types'

export type StatusFilter = 'all' | 'active' | 'queued' | 'paused' | 'completed' | 'seeding' | 'failed'

/** The Mac app's Type group. Keys are `fileType()` values, so no second classifier exists. */
export type TypeFilter = Exclude<FileType, 'magnet'>

export type Filter = StatusFilter | TypeFilter

export type FilterCounts = Record<Filter, number>

export const TYPE_FILTERS: readonly TypeFilter[] = [
  'video',
  'audio',
  'image',
  'iso',
  'archive',
  'app',
  'doc',
  'other',
]

const TYPE_SET: ReadonlySet<Filter> = new Set<Filter>(TYPE_FILTERS)

export function isTypeFilter(filter: Filter): filter is TypeFilter {
  return TYPE_SET.has(filter)
}

export function matchesFilter(task: TaskRow, filter: Filter): boolean {
  if (filter === 'all') return true
  // Queued has its own entry, as in the native sidebar, so Active means work actually running.
  if (filter === 'active') return isActive(task.statusToken) && task.statusToken !== 'queued'
  if (isTypeFilter(filter)) return fileType(task) === filter
  return task.statusToken === filter
}

export function countFilters(tasks: readonly TaskRow[]): FilterCounts {
  const zero: FilterCounts = {
    all: 0,
    active: 0,
    queued: 0,
    paused: 0,
    completed: 0,
    seeding: 0,
    failed: 0,
    video: 0,
    audio: 0,
    image: 0,
    iso: 0,
    archive: 0,
    app: 0,
    doc: 0,
    other: 0,
  }
  const keys = Object.keys(zero) as Filter[]
  return Object.fromEntries(
    keys.map((key) => [key, tasks.filter((t) => matchesFilter(t, key)).length]),
  ) as FilterCounts
}

/** Name search plus sidebar filter: the list the user actually sees, before sorting. */
export function filterTasks(
  tasks: readonly TaskRow[],
  filter: Filter,
  search: string,
): TaskRow[] {
  const needle = search.trim().toLowerCase()
  return tasks.filter(
    (t) => (!needle || t.name.toLowerCase().includes(needle)) && matchesFilter(t, filter),
  )
}
