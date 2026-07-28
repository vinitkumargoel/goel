import { BOOT } from './boot'

/** Mirrored from `Theme.swift` and `styles/themes.css` — a new theme must be added in all three. */
export const THEMES = ['frost-light', 'frost-dark', 'dracula', 'nord'] as const

export type Theme = (typeof THEMES)[number]

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

function isTheme(value: string | null): value is Theme {
  return value != null && (THEMES as readonly string[]).includes(value)
}

/** `localStorage` throws in private-mode Safari and when cookies are blocked. */
function readStored(): Theme | null {
  try {
    const v = localStorage.getItem(STORAGE_KEY)
    return isTheme(v) ? v : null
  } catch {
    return null
  }
}

function writeStored(theme: Theme): void {
  try {
    localStorage.setItem(STORAGE_KEY, theme)
  } catch {
    // Swallowed: a throwing theme switch would leave the settings pane half-rendered.
  }
}

/** Never persist `BOOT.theme`: a browser follows the desktop default only while nothing is stored. */
export function initialTheme(): Theme {
  const stored = readStored()
  if (stored) return stored
  return isTheme(BOOT.theme) ? BOOT.theme : 'frost-dark'
}

export function applyTheme(theme: Theme, persist: boolean): void {
  document.documentElement.dataset['theme'] = theme
  if (persist) writeStored(theme)
}
