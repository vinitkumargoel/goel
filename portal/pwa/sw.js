// Goel° portal service worker. It caches nothing: every page and API call goes to the server,
// which holds the session. It exists so an installed portal opens to a clear "server
// unreachable" screen instead of the browser's own error page when the daemon is down.

// The portal's own canvas and ink (styles/themes.css, light and dark), so the offline page looks
// like the app rather than a browser error. Two languages are enough for a screen that shows
// for seconds; the app itself carries the full catalogue.
const COPY = {
  en: {
    bar: 'Reconnecting to Goel°…',
    title: 'Can’t reach the Goel° server',
    body: 'Check that the daemon is running and this device is on the same network. This page retries every 10 seconds.',
    retry: 'Try again now',
    tab: 'Goel° — Reconnecting',
  },
  de: {
    bar: 'Verbindung zu Goel° wird wiederhergestellt …',
    title: 'Goel°-Server nicht erreichbar',
    body: 'Prüfe, ob der Daemon läuft und dieses Gerät im selben Netzwerk ist. Diese Seite versucht es alle 10 Sekunden erneut.',
    retry: 'Jetzt erneut versuchen',
    tab: 'Goel° — Verbindung wird hergestellt',
  },
}

function offlineHtml(language) {
  const lang = String(language || 'en').toLowerCase().startsWith('de') ? 'de' : 'en'
  const c = COPY[lang]
  return `<!doctype html><html lang="${lang}"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="10">
<title>${c.tab}</title>
<style>
  :root { color-scheme: light dark; --canvas: #f1f7f2; --ink: #18251f; --ink-2: #4c5953; --accent: #007d5f;
          --warn: #8a4b00; --warn-bg: rgba(200, 120, 0, .14); }
  @media (prefers-color-scheme: dark) {
    :root { --canvas: #121e18; --ink: #e9f1ec; --ink-2: #b2beb7; --accent: #52caa5;
            --warn: #f0b86a; --warn-bg: rgba(240, 184, 106, .16); }
  }
  body { margin: 0; font: 15px/1.5 -apple-system, system-ui, sans-serif; background: var(--canvas);
         color: var(--ink); display: grid; min-height: 100vh; place-items: center; }
  .bar { position: fixed; top: 0; left: 0; right: 0; padding: 8px 16px; background: var(--warn-bg);
         color: var(--warn); font-weight: 600; text-align: center; }
  main { max-width: 360px; padding: 24px; text-align: center; }
  h1 { font-size: 20px; margin: 0 0 8px; }
  p { margin: 0 0 16px; color: var(--ink-2); }
  a { color: var(--accent); font-weight: 600; }
</style></head><body>
<div class="bar" role="status">${c.bar}</div>
<main><h1>${c.title}</h1>
<p>${c.body}</p>
<a href="/">${c.retry}</a></main>
</body></html>`
}

self.addEventListener('install', () => self.skipWaiting())
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()))

self.addEventListener('fetch', (event) => {
  // Only whole-page loads: the event stream, streams and API calls must reach the server untouched.
  if (event.request.mode !== 'navigate') return
  event.respondWith(
    fetch(event.request).catch(
      () =>
        new Response(offlineHtml(self.navigator.language), {
          status: 503,
          headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' },
        }),
    ),
  )
})
