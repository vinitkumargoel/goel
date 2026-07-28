import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { App } from './App'
import { applyTheme, initialTheme } from './lib/theme'
import './styles/themes.css'
import './styles/portal.css'

/** The QR deep link carries the API token in the URL; the server already exchanged it for a cookie, so drop it before it reaches a bookmark or screenshot. */
try {
  if (location.search.includes('token=')) {
    history.replaceState(null, '', location.pathname + location.hash)
  }
} catch {
  // `replaceState` throws on a `file://` origin or in a sandboxed frame; failing to tidy the URL must not stop startup.
}

applyTheme(initialTheme(), false)

const container = document.getElementById('root')
if (!container) throw new Error('#root is missing from the page shell')

createRoot(container).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
