import { BOOT } from './boot'

/** Mirrored from `Theme.swift` and `styles/themes.css` — a new theme must be added in all three. */
export const THEMES = ['frost-light', 'frost-dark', 'dracula', 'nord'] as const

export type Theme = (typeof THEMES)[number]

/**
 * What the user picked: a concrete theme, or `auto`, which follows the OS light/dark setting via
 * the Frost pair. `auto` is web-only — the desktop never sends it, and it is never written to `data-theme`.
 */
export type ThemeChoice = Theme | 'auto'

export const AUTO_THEME = 'auto' as const

export const THEME_LABEL: Record<Theme, string> = {
  'frost-light': 'Frost Light',
  'frost-dark': 'Frost Dark',
  dracula: 'Dracula',
  nord: 'Nord',
}

export const THEME_ACCENT: Record<Theme, string> = {
  'frost-light': '#3F58D6',
  'frost-dark': '#8AA2FF',
  dracula: '#BD93F9',
  nord: '#88C0D0',
}

const STORAGE_KEY = 'goel-web-theme'
const DARK_QUERY = '(prefers-color-scheme: dark)'

function isTheme(value: string | null): value is Theme {
  return value != null && (THEMES as readonly string[]).includes(value)
}

function isChoice(value: string | null): value is ThemeChoice {
  return value === AUTO_THEME || isTheme(value)
}

/** `localStorage` throws in private-mode Safari and when cookies are blocked. */
function readStored(): ThemeChoice | null {
  try {
    const v = localStorage.getItem(STORAGE_KEY)
    return isChoice(v) ? v : null
  } catch {
    return null
  }
}

function writeStored(choice: ThemeChoice): void {
  try {
    localStorage.setItem(STORAGE_KEY, choice)
  } catch {
    // Swallowed: a throwing theme switch would leave the settings pane half-rendered.
  }
}

/**
 * The stored choice, else Auto. A desktop default of Dracula or Nord is a deliberate pick with no
 * light twin, so a new browser starts on it; the Frost defaults defer to the OS setting instead.
 * `BOOT.theme` is never persisted: a browser follows the desktop only while nothing is stored.
 */
export function initialTheme(): ThemeChoice {
  const stored = readStored()
  if (stored) return stored
  return BOOT.theme === 'dracula' || BOOT.theme === 'nord' ? BOOT.theme : AUTO_THEME
}

/** Whether the OS asks for a dark appearance. Dark where `matchMedia` is missing, the old default. */
export function systemPrefersDark(): boolean {
  if (typeof window.matchMedia !== 'function') return true
  return window.matchMedia(DARK_QUERY).matches
}

/** The concrete theme a choice paints with. */
export function resolveTheme(choice: ThemeChoice, prefersDark: boolean): Theme {
  if (choice !== AUTO_THEME) return choice
  return prefersDark ? 'frost-dark' : 'frost-light'
}

export function applyTheme(choice: ThemeChoice, persist: boolean): void {
  document.documentElement.dataset['theme'] = resolveTheme(choice, systemPrefersDark())
  if (persist) writeStored(choice)
}

/** Calls `onChange` whenever the OS appearance flips. Returns the unsubscribe. */
export function watchSystemTheme(onChange: (prefersDark: boolean) => void): () => void {
  if (typeof window.matchMedia !== 'function') return () => {}
  const list = window.matchMedia(DARK_QUERY)
  const listener = (e: MediaQueryListEvent) => onChange(e.matches)
  list.addEventListener('change', listener)
  return () => list.removeEventListener('change', listener)
}
