/** Inert JSON under CSP `script-src 'self'`; `bootJSON(config:)` must escape `<`. */
export interface BootConfig {
  theme: string
  username: string
  readOnly: boolean
  requireAuth: boolean
  /** Which machine serves the portal: Settings words its "managed elsewhere" copy by it. */
  host: 'mac' | 'linux'
  hostname: string
}

const FALLBACK: BootConfig = {
  theme: 'frost-dark',
  username: 'admin',
  readOnly: false,
  requireAuth: true,
  host: 'mac',
  hostname: '',
}

/** `readOnly` is UI chrome only — the server, not this default, enforces the 403. */
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
    host: b.host === 'linux' ? 'linux' : 'mac',
    hostname: typeof b.hostname === 'string' ? b.hostname : '',
  }
}

export const BOOT: BootConfig = readBoot()
