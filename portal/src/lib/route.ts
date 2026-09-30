import type { Filter } from './filters'
import type { SortKey, SortState } from './sort'
import { UNSORTED } from './sort'

export type RouteView = 'library' | 'history' | 'settings'

/** What the address bar carries: the view, the library filter, and the selected download. */
export interface Route {
  view: RouteView
  filter: Filter
  task: string | null
}

const FILTERS: ReadonlySet<string> = new Set<Filter>([
  'all', 'active', 'paused', 'completed', 'seeding', 'failed', 'video', 'iso', 'archive', 'app',
])

export const HOME: Route = { view: 'library', filter: 'all', task: null }

/** `#/library/failed?task=<id>`, `#/history`, `#/settings`; anything unknown falls back to the library. */
export function parseRoute(hash: string): Route {
  const [path = '', query = ''] = hash.replace(/^#\/?/, '').split('?', 2)
  const [head, sub] = path.split('/')
  if (head === 'history' || head === 'settings') return { ...HOME, view: head }
  const filter = sub && FILTERS.has(sub) ? (sub as Filter) : 'all'
  const task = new URLSearchParams(query).get('task')
  return { view: 'library', filter, task: task || null }
}

export function formatRoute(route: Route): string {
  if (route.view !== 'library') return `#/${route.view}`
  const base = route.filter === 'all' ? '#/library' : `#/library/${route.filter}`
  return route.task ? `${base}?task=${encodeURIComponent(route.task)}` : base
}

const SORT_KEY = 'goel.sort'
const SORT_KEYS: ReadonlySet<string> = new Set<SortKey>(['name', 'size', 'status', 'speed', 'eta', 'added'])

/** The list order is a per-browser habit, so it survives reloads; storage may be unavailable. */
export function loadSort(): SortState {
  try {
    const raw = localStorage.getItem(SORT_KEY)
    if (!raw) return UNSORTED
    const s = JSON.parse(raw) as Partial<SortState>
    const key = typeof s.key === 'string' && SORT_KEYS.has(s.key) ? (s.key as SortKey) : null
    return key ? { key, dir: s.dir === 'desc' ? 'desc' : 'asc' } : UNSORTED
  } catch {
    return UNSORTED
  }
}

export function saveSort(sort: SortState): void {
  try {
    if (sort.key == null) localStorage.removeItem(SORT_KEY)
    else localStorage.setItem(SORT_KEY, JSON.stringify(sort))
  } catch {
    // A convenience: without storage the order simply resets on reload.
  }
}
