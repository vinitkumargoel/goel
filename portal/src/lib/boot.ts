/**
 * The per-session values the server inlines into the page shell.
 *
 * Delivered as `<script id="goel-boot" type="application/json">` rather than an
 * inline assignment, because the portal's Content-Security-Policy is
 * `script-src 'self'` — no inline script executes. A JSON script element is
 * inert data, not code, so it is unaffected by that and needs no nonce or hash
 * plumbed through every response.
 *
 * Produced by `bootJSON(config:)` in `RemotePortalPage.swift`, which escapes
 * `<` so a username cannot close the element early.
 *
 * These same values are available from `GET /api/config`; having them in the
 * document saves a round trip before the first paint.
 */
export interface BootConfig {
  /** One of the four known theme tokens; `AppThemeToken.sanitize` guarantees it. */
  theme: string
  username: string
  readOnly: boolean
  requireAuth: boolean
}

const FALLBACK: BootConfig = {
  theme: 'frost-dark',
  username: 'admin',
  readOnly: false,
  requireAuth: true,
}

/**
 * Never throws. If the shell served no boot data the portal should still render
 * and let the API's 401 push the user to `/login`, rather than showing a blank
 * page with an error visible only in the console.
 *
 * `readOnly` falls back to `false` rather than `true`: the server enforces
 * read-only itself — every POST is refused with 403 before routing — so a wrong
 * guess here costs a rejected request and a toast, not a bypass.
 */
export function readBoot(): BootConfig {
  const raw = document.getElementById('goel-boot')?.textContent
  if (!raw) return FALLBACK

  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch {
    return FALLBACK
  }
  if (typeof parsed !== 'object' || parsed === null) return FALLBACK

  const b = parsed as Partial<BootConfig>
  return {
    theme: typeof b.theme === 'string' ? b.theme : FALLBACK.theme,
    username: typeof b.username === 'string' ? b.username : FALLBACK.username,
    readOnly: b.readOnly === true,
    requireAuth: b.requireAuth !== false,
  }
}

export const BOOT: BootConfig = readBoot()
