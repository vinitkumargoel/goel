import { BOOT } from './boot'

/** The four named themes, mirrored from `Theme.swift` and defined in `styles/themes.css`. The desktop
 * app sets a fresh browser's default; the choice made here is per-browser and independent of it. */
export const THEMES = ['frost-light', 'frost-dark', 'dracula', 'nord'] as const

export type Theme = (typeof THEMES)[number]

export const THEME_LABEL: Record<Theme, string> = {
  'frost-light': 'Frost Light',
  'frost-dark': 'Frost Dark',
  dracula: 'Dracula',
  nord: 'Nord',
}

/** Swatch colours for the settings picker — each theme's `--accent`. */
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
    // A theme that doesn't survive a reload is a much smaller problem than a
    // theme switch that throws and leaves the settings pane half-rendered.
  }
}

/** The theme to start from: the user's own choice if made, else the server's default. A browser that
 * never picked keeps *following* the desktop — which works only because that default is never stored. */
export function initialTheme(): Theme {
  const stored = readStored()
  if (stored) return stored
  return isTheme(BOOT.theme) ? BOOT.theme : 'frost-dark'
}

/** Themes are CSS variables keyed off `html[data-theme]`, so switching is one attribute write and no
 * re-render of anything that isn't already reading a variable. */
export function applyTheme(theme: Theme, persist: boolean): void {
  document.documentElement.dataset['theme'] = theme
  if (persist) writeStored(theme)
}
