import type { Filter } from './filters'

type Digit = 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9

export type ShortcutId =
  | 'search'
  | 'add'
  | 'toggle'
  | 'remove'
  | 'next'
  | 'prev'
  | 'open'
  | 'help'
  | 'retry'
  | 'copy'
  /** The first key of G H / G S; the next key decides (see `resolveGo`). */
  | 'go'
  | 'go-history'
  | 'go-settings'
  | `filter-${Digit}`

/** 1–9 jump to the sidebar's filters, in its order: All, the six statuses, then the first types. */
export const FILTER_KEYS: readonly Filter[] = [
  'all',
  'active',
  'queued',
  'paused',
  'completed',
  'seeding',
  'failed',
  'video',
  'audio',
]

/** How long after G the second key still counts. */
export const GO_WINDOW_MS = 1500

type ShortcutLabel =
  | 'shortcuts.search'
  | 'shortcuts.next'
  | 'shortcuts.prev'
  | 'shortcuts.open'
  | 'shortcuts.selectAll'
  | 'shortcuts.toggleSelect'
  | 'shortcuts.close'
  | 'shortcuts.help'
  | 'shortcuts.add'
  | 'shortcuts.toggle'
  | 'shortcuts.remove'
  | 'workflow.shortcuts.palette'
  | 'workflow.shortcuts.filters'
  | 'workflow.shortcuts.history'
  | 'workflow.shortcuts.settings'
  | 'workflow.shortcuts.retry'
  | 'workflow.shortcuts.copy'
  | 'workflow.shortcuts.paste'

export interface ShortcutDoc {
  keys: readonly string[]
  labelKey: ShortcutLabel
  /** Pressed one after the other (G then H), not together. */
  sequence?: boolean
}

/** The cheat sheet, in display order. Key names are glyphs and stay untranslated. */
export const SHORTCUT_DOCS: { navigation: readonly ShortcutDoc[]; actions: readonly ShortcutDoc[] } = {
  navigation: [
    { keys: ['⌘/Ctrl', 'K'], labelKey: 'workflow.shortcuts.palette' },
    { keys: ['/'], labelKey: 'shortcuts.search' },
    { keys: ['1–9'], labelKey: 'workflow.shortcuts.filters' },
    { keys: ['G', 'H'], labelKey: 'workflow.shortcuts.history', sequence: true },
    { keys: ['G', 'S'], labelKey: 'workflow.shortcuts.settings', sequence: true },
    { keys: ['J'], labelKey: 'shortcuts.next' },
    { keys: ['K'], labelKey: 'shortcuts.prev' },
    { keys: ['Enter'], labelKey: 'shortcuts.open' },
    { keys: ['⌘/Ctrl', 'A'], labelKey: 'shortcuts.selectAll' },
    { keys: ['⌘/Ctrl', 'Space'], labelKey: 'shortcuts.toggleSelect' },
    { keys: ['Esc'], labelKey: 'shortcuts.close' },
    { keys: ['?'], labelKey: 'shortcuts.help' },
  ],
  actions: [
    { keys: ['N'], labelKey: 'shortcuts.add' },
    { keys: ['Space'], labelKey: 'shortcuts.toggle' },
    { keys: ['Delete'], labelKey: 'shortcuts.remove' },
    { keys: ['R'], labelKey: 'workflow.shortcuts.retry' },
    { keys: ['C'], labelKey: 'workflow.shortcuts.copy' },
    { keys: ['⌘/Ctrl', 'V'], labelKey: 'workflow.shortcuts.paste' },
  ],
}

/** The fields of a KeyboardEvent the resolver reads, so tests can pass plain objects. */
export interface KeyLike {
  key: string
  metaKey?: boolean
  ctrlKey?: boolean
  altKey?: boolean
  defaultPrevented?: boolean
  repeat?: boolean
  target: EventTarget | null
}

function isTextEntry(el: Element): boolean {
  if (el instanceof HTMLElement && el.isContentEditable) return true
  if (el.closest('[contenteditable=""],[contenteditable="true"]')) return true
  const tag = el.tagName
  return tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT'
}

/**
 * Space, Enter and Delete mean something to whatever has focus (a button presses, a row toggles),
 * so they act globally only from the page itself or a row — never from another control.
 */
function ownsActivationKeys(el: Element | null): boolean {
  return el == null || el === document.body || el.getAttribute('role') === 'option'
}

/** A menu's items take letters for type-ahead and Space/Enter to activate; none of it is ours. */
function isInMenu(el: Element): boolean {
  return (el.getAttribute('role') ?? '').startsWith('menuitem') || el.closest('[role="menu"]') != null
}

/** Which shortcut a keydown is, or null when it belongs to someone else. */
export function resolveShortcut(e: KeyLike): ShortcutId | null {
  if (e.defaultPrevented || e.metaKey || e.ctrlKey || e.altKey) return null
  const target = e.target instanceof Element ? e.target : null
  if (target && (isTextEntry(target) || isInMenu(target))) return null

  switch (e.key) {
    case '/':
      return 'search'
    case '?':
      return 'help'
    case 'n':
    case 'N':
      return 'add'
    case 'j':
    case 'J':
      return 'next'
    case 'k':
    case 'K':
      return 'prev'
    case 'g':
    case 'G':
      return 'go'
    case 'r':
    case 'R':
      return 'retry'
    case 'c':
    case 'C':
      return 'copy'
  }
  if (/^[1-9]$/.test(e.key)) return `filter-${Number(e.key) as Digit}`
  // Held keys auto-repeat: harmless for J/K, but Space would flip pause/resume and Delete re-ask.
  if (!ownsActivationKeys(target) || e.repeat) return null
  switch (e.key) {
    case ' ':
      return 'toggle'
    case 'Enter':
      return 'open'
    case 'Delete':
    case 'Backspace':
      return 'remove'
  }
  return null
}

/** The key after G: H for History, S for Settings, anything else ends the sequence. */
export function resolveGo(e: KeyLike): ShortcutId | null {
  if (e.metaKey || e.ctrlKey || e.altKey) return null
  const key = e.key.toLowerCase()
  if (key === 'h') return 'go-history'
  if (key === 's') return 'go-settings'
  return null
}

/** The sidebar filter a digit shortcut stands for. */
export function filterForShortcut(id: ShortcutId): Filter | null {
  const m = /^filter-(\d)$/.exec(id)
  return m ? (FILTER_KEYS[Number(m[1]) - 1] ?? null) : null
}

/** ⌘/Ctrl+K: the command palette, from anywhere including a text field. */
export function isPaletteKey(e: KeyLike & { shiftKey?: boolean }): boolean {
  return (e.metaKey || e.ctrlKey) === true && !e.altKey && !e.shiftKey && e.key.toLowerCase() === 'k'
}
