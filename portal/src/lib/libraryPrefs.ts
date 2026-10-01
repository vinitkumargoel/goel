import { GROUP_BYS, type GroupBy } from './grouping'

/** How the library looks, per browser: grouping, row density and table vs cards. */
export type Density = 'comfortable' | 'compact'
export type LibraryLayout = 'table' | 'cards'

export interface LibraryPrefs {
  group: GroupBy
  density: Density
  layout: LibraryLayout
}

export const DEFAULT_LIBRARY_PREFS: LibraryPrefs = { group: 'none', density: 'comfortable', layout: 'table' }

const KEYS = { group: 'goel.library.group', density: 'goel.library.density', layout: 'goel.library.view' } as const
const ALLOWED: { [K in keyof LibraryPrefs]: readonly LibraryPrefs[K][] } = {
  group: GROUP_BYS,
  density: ['comfortable', 'compact'],
  layout: ['table', 'cards'],
}

function read<K extends keyof LibraryPrefs>(key: K): LibraryPrefs[K] {
  try {
    const raw = localStorage.getItem(KEYS[key])
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
