import { BOOT } from './boot'

/**
 * The two Studio palettes, mirrored from StudioPalette.swift and `styles/themes.css`. `auto`
 * follows the OS light/dark setting; it is a choice, never a value written to `data-theme`.
 */
export const THEMES = ['light', 'dark'] as const

export type Theme = (typeof THEMES)[number]

export type ThemeChoice = Theme | 'auto'

export const AUTO_THEME = 'auto' as const

/** The order Settings and the palette offer them in. */
export const THEME_CHOICES: readonly ThemeChoice[] = ['light', 'dark', AUTO_THEME]

/**
 * Values from before Studio — the desktop's `remoteTheme` and what a browser stored under
 * `goel-web-theme` — and the Studio palette each now paints with.
 */
export const LEGACY_THEMES: Readonly<Record<string, Theme>> = {
  'frost-light': 'light',
  'frost-dark': 'dark',
  dracula: 'dark',
  nord: 'dark',
}

const STORAGE_KEY = 'goel-web-theme'
const DARK_QUERY = '(prefers-color-scheme: dark)'

/** Any accepted value, current or legacy, as a choice; null for anything else. */
export function normalizeTheme(value: string | null | undefined): ThemeChoice | null {
  if (value == null) return null
  if (value === AUTO_THEME || (THEMES as readonly string[]).includes(value)) return value as ThemeChoice
  return LEGACY_THEMES[value] ?? null
}

/** `localStorage` throws in private-mode Safari and when cookies are blocked. */
function readStored(): ThemeChoice | null {
  try {
    return normalizeTheme(localStorage.getItem(STORAGE_KEY))
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
 * The stored choice, else what the desktop asked for, else Auto.
 *
 * The desktop's value is followed only while this browser has stored nothing, and is never
 * persisted. `light`, `dark` and `auto` are taken as given. Of the legacy values, Dracula and
 * Nord were deliberate dark picks with no light twin, so they start dark; the Frost pair was the
 * desktop default and keeps deferring to the OS, as it always did.
 */
export function initialTheme(): ThemeChoice {
  const stored = readStored()
  if (stored) return stored
  const boot = BOOT.theme
  if (boot === 'frost-light' || boot === 'frost-dark') return AUTO_THEME
  return normalizeTheme(boot) ?? AUTO_THEME
}

/** Whether the OS asks for a dark appearance. Light where `matchMedia` is missing. */
export function systemPrefersDark(): boolean {
  if (typeof window.matchMedia !== 'function') return false
  return window.matchMedia(DARK_QUERY).matches
}

/** The concrete palette a choice paints with. */
export function resolveTheme(choice: ThemeChoice, prefersDark: boolean): Theme {
  if (choice !== AUTO_THEME) return choice
  return prefersDark ? 'dark' : 'light'
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
