import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { App } from './App'
import { applyTheme, initialTheme } from './lib/theme'
import './styles/themes.css'
import './styles/portal.css'

/** The QR deep link puts the API token in the address bar; the server has already exchanged it for
 *  a cookie, so drop it before the first render — it must not linger in a bookmark or screenshot. */
try {
  if (location.search.includes('token=')) {
    history.replaceState(null, '', location.pathname + location.hash)
  }
} catch {
  // `replaceState` throws on a `file://` origin and in a sandboxed frame — neither is a context
  // the portal is served from, and failing to tidy the URL is not a reason to refuse to start.
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
