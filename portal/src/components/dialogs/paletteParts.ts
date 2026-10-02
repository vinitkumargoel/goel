import type { PaletteCommand } from '../../lib/palette'
import type { IconName } from '../ui/Icon'

const BY_ID: Readonly<Record<string, IconName>> = {
  add: 'plus',
  all: 'list',
  history: 'history',
  settings: 'settings',
  panel: 'sidebar',
  help: 'keyboard',
  pauseAll: 'pause',
  resumeAll: 'play',
  retryFailed: 'retry',
  'theme:light': 'sun',
  'theme:dark': 'moon',
  'theme:auto': 'sparkle',
  'layout:board': 'board',
  'layout:table': 'list',
  'density:compact': 'menu',
  'density:comfortable': 'grid',
}

const BY_PREFIX: ReadonlyArray<readonly [string, IconName]> = [
  ['task:', 'down'],
  ['f:', 'filter'],
  ['group:', 'sort'],
  ['theme:', 'sun'],
]

const BY_GROUP: Readonly<Record<PaletteCommand['group'], IconName>> = {
  add: 'plus',
  downloads: 'down',
  view: 'eye',
  actions: 'bolt',
  settings: 'settings',
}

/** The glyph at the start of a palette row: by command, then by kind of command, then by group. */
export function commandIcon(c: Pick<PaletteCommand, 'id' | 'group'>): IconName {
  const exact = BY_ID[c.id]
  if (exact) return exact
  const prefixed = BY_PREFIX.find(([p]) => c.id.startsWith(p))
  return prefixed ? prefixed[1] : BY_GROUP[c.group]
}

/**
 * The label split around the first place a query word appears, so the row can embolden what was
 * typed ("Pa" in "Pause all"). A scattered fuzzy match has no single run, and stays plain.
 */
export function highlight(label: string, query: string): { before: string; hit: string; after: string } | null {
  const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean)
  const lower = label.toLowerCase()
  for (const w of words) {
    const at = lower.indexOf(w)
    if (at >= 0) return { before: label.slice(0, at), hit: label.slice(at, at + w.length), after: label.slice(at + w.length) }
  }
  return null
}
