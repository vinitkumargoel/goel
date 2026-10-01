// Goel° portal service worker. It caches nothing: every page and API call goes to the server,
// which holds the session. It exists so an installed portal opens to a clear "server
// unreachable" screen instead of the browser's own error page when the daemon is down.

const OFFLINE_HTML = `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="10">
<title>Goel° — Reconnecting</title>
<style>
  :root { color-scheme: light dark; }
  body { margin: 0; font: 15px/1.5 -apple-system, system-ui, sans-serif; background: #15171d; color: #eef1f7;
         display: grid; min-height: 100vh; place-items: center; }
  @media (prefers-color-scheme: light) { body { background: #f4f6fa; color: #1a1c22; } }
  .bar { position: fixed; top: 0; left: 0; right: 0; padding: 8px 16px; background: rgba(251,191,107,.18);
         color: #fbbf6b; font-weight: 600; text-align: center; }
  @media (prefers-color-scheme: light) { .bar { color: #a85800; } }
  main { max-width: 360px; padding: 24px; text-align: center; }
  h1 { font-size: 20px; margin: 0 0 8px; }
  p { margin: 0 0 16px; opacity: .8; }
  a { color: #8aa2ff; }
</style></head><body>
<div class="bar" role="status">Reconnecting to Goel°…</div>
<main><h1>Can’t reach the Goel° server</h1>
<p>Check that the daemon is running and this device is on the same network. This page retries every 10 seconds.</p>
<a href="/">Try again now</a></main>
</body></html>`

self.addEventListener('install', () => self.skipWaiting())
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()))

self.addEventListener('fetch', (event) => {
  // Only whole-page loads: the event stream, streams and API calls must reach the server untouched.
  if (event.request.mode !== 'navigate') return
  event.respondWith(
    fetch(event.request).catch(
      () =>
        new Response(OFFLINE_HTML, {
          status: 503,
          headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' },
        }),
    ),
  )
})
