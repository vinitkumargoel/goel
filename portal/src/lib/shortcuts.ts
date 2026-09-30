export type ShortcutId = 'search' | 'add' | 'toggle' | 'remove' | 'next' | 'prev' | 'open' | 'help'

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

export interface ShortcutDoc {
  keys: readonly string[]
  labelKey: ShortcutLabel
}

/** The cheat sheet, in display order. Key names are glyphs and stay untranslated. */
export const SHORTCUT_DOCS: { navigation: readonly ShortcutDoc[]; actions: readonly ShortcutDoc[] } = {
  navigation: [
    { keys: ['/'], labelKey: 'shortcuts.search' },
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
  }
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
