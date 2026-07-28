/** Per-session values inlined as `<script id="goel-boot" type="application/json">` — the portal CSP is
 * `script-src 'self'`, so inert JSON needs no nonce. `bootJSON(config:)` builds it and escapes `<`. */
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

/** Never throws: with no boot data the portal still renders and the API's 401 pushes the user to `/login`.
 * `readOnly` defaults `false`: the server refuses every POST with 403 anyway, so a wrong guess is no bypass. */
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
