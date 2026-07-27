import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { App } from './App'
import { applyTheme, initialTheme } from './lib/theme'
import './styles/themes.css'
import './styles/portal.css'

/**
 * The QR / deep link puts the API token in the address bar. The server has
 * already turned it into a session cookie by the time this runs, so drop it
 * from the visible URL and from history — it must not linger in the bar, in a
 * bookmark, or in a screenshot.
 *
 * This happens before the first render so the token is never visible, even
 * briefly, on a slow device.
 */
try {
  if (location.search.includes('token=')) {
    history.replaceState(null, '', location.pathname + location.hash)
  }
} catch {
  // `replaceState` throws on a `file://` origin and in a sandboxed frame.
  // Neither is a context the portal is served from, and failing to tidy the URL
  // is not a reason to refuse to start.
}

// Paint the theme before React mounts, so the first frame is not the default
// dark palette flashing to the user's actual choice.
applyTheme(initialTheme(), false)

const container = document.getElementById('root')
if (!container) throw new Error('#root is missing from the page shell')

createRoot(container).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
