/** Inert JSON under CSP `script-src 'self'`; `bootJSON(config:)` must escape `<`. */
export interface BootConfig {
  theme: string
  username: string
  readOnly: boolean
  requireAuth: boolean
  /** Which machine serves the portal: Settings words its "managed elsewhere" copy by it. */
  host: 'mac' | 'linux'
  hostname: string
  /** The server's UI language ("de"); the portal starts in it unless this browser chose another. */
  language: string
}

const FALLBACK: BootConfig = {
  theme: 'auto',
  username: 'admin',
  readOnly: false,
  requireAuth: true,
  host: 'mac',
  hostname: '',
  language: '',
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
    language: typeof b.language === 'string' ? b.language : '',
  }
}

export const BOOT: BootConfig = readBoot()
