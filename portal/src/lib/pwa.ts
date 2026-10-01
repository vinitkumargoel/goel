/**
 * Installable-app glue: the service worker (offline "reconnecting" shell only — it caches nothing)
 * and the `theme-color` meta, which tints the phone status bar and the installed window's title bar.
 */

export function registerServiceWorker(): void {
  if (!('serviceWorker' in navigator)) return
  // After load, so registering never competes with the first paint for the connection.
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('/sw.js', { scope: '/' }).catch(() => {
      // An http:// LAN address is not a secure context: no worker, the portal works the same.
    })
  })
}

function themeMeta(): HTMLMetaElement {
  let meta = document.querySelector<HTMLMetaElement>('meta[name="theme-color"]')
  if (!meta) {
    meta = document.createElement('meta')
    meta.name = 'theme-color'
    document.head.append(meta)
  }
  return meta
}

/** The page's own background, so every theme (and Auto's light/dark flip) is matched without a table. */
export function syncThemeColor(): void {
  const color = getComputedStyle(document.body).backgroundColor
  if (color && color !== 'rgba(0, 0, 0, 0)') themeMeta().content = color
}

/** Re-syncs whenever the theme attribute or the system appearance changes. */
export function watchThemeColor(): () => void {
  syncThemeColor()
  const observer = new MutationObserver(() => syncThemeColor())
  observer.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme', 'class', 'style'] })
  const scheme = window.matchMedia?.('(prefers-color-scheme: dark)')
  const onScheme = () => requestAnimationFrame(syncThemeColor)
  scheme?.addEventListener?.('change', onScheme)
  return () => {
    observer.disconnect()
    scheme?.removeEventListener?.('change', onScheme)
  }
}
