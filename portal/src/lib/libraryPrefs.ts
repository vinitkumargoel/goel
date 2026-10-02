import { GROUP_BYS, type GroupBy } from './grouping'

/** How the library looks, per browser: grouping, row density and Board vs Table. */
export type Density = 'comfortable' | 'compact'
export type LibraryLayout = 'board' | 'table'

export interface LibraryPrefs {
  group: GroupBy
  density: Density
  layout: LibraryLayout
}

/** The Board is Studio's home view, as in the app; the Table is there for big queues. */
export const DEFAULT_LIBRARY_PREFS: LibraryPrefs = { group: 'none', density: 'comfortable', layout: 'board' }

/** Values stored before Studio, and what they mean now: the old Cards view became the Board. */
const LEGACY: Readonly<Record<string, string>> = { cards: 'board' }

const KEYS = { group: 'goel.library.group', density: 'goel.library.density', layout: 'goel.library.view' } as const
const ALLOWED: { [K in keyof LibraryPrefs]: readonly LibraryPrefs[K][] } = {
  group: GROUP_BYS,
  density: ['comfortable', 'compact'],
  layout: ['board', 'table'],
}

function read<K extends keyof LibraryPrefs>(key: K): LibraryPrefs[K] {
  try {
    const stored = localStorage.getItem(KEYS[key])
    const raw = stored != null ? (LEGACY[stored] ?? stored) : null
    const allowed = ALLOWED[key] as readonly string[]
    if (raw != null && allowed.includes(raw)) return raw as LibraryPrefs[K]
  } catch {
    // Blocked storage: the default.
  }
  return DEFAULT_LIBRARY_PREFS[key]
}

export function loadLibraryPrefs(): LibraryPrefs {
  return { group: read('group'), density: read('density'), layout: read('layout') }
}

export function saveLibraryPref<K extends keyof LibraryPrefs>(key: K, value: LibraryPrefs[K]): void {
  try {
    localStorage.setItem(KEYS[key], value)
  } catch {
    // Not remembered, but still applied for this visit.
  }
}
