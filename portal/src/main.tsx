// First: in dev with `?fixtures` it swaps in a fake daemon before anything reads the boot values.
import './dev/install'
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { I18nextProvider } from 'react-i18next'
import { App } from './App'
import i18n from './i18n'
import { registerServiceWorker, watchThemeColor } from './lib/pwa'
import { applyTheme, initialTheme } from './lib/theme'
import './styles/fonts.css'
import './styles/themes.css'
import './styles/base.css'
import './styles/base-controls.css'
import './styles/base-surfaces.css'
import './styles/base-layers.css'
import './styles/shell.css'
import './styles/library.css'
import './styles/library-table.css'
import './styles/detail.css'
import './styles/detail-panes.css'
import './styles/dialogs.css'
import './styles/history.css'
import './styles/settings.css'
import './styles/palette.css'

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

watchThemeColor()
if (import.meta.env.PROD) registerServiceWorker()

createRoot(container).render(
  <StrictMode>
    <I18nextProvider i18n={i18n}>
      <App />
    </I18nextProvider>
  </StrictMode>,
)
