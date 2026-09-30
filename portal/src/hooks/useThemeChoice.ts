import { useEffect, useState } from 'react'
import { applyTheme, AUTO_THEME, initialTheme, watchSystemTheme, type ThemeChoice } from '../lib/theme'

/** The theme choice, painted on change; while it is Auto, an OS light/dark flip repaints live. */
export function useThemeChoice() {
  const [theme, setTheme] = useState<ThemeChoice>(initialTheme)

  useEffect(() => {
    applyTheme(theme, false)
    if (theme !== AUTO_THEME) return
    return watchSystemTheme(() => applyTheme(AUTO_THEME, false))
  }, [theme])

  return [theme, setTheme] as const
}
