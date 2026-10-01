/**
 * Which catalogue the portal speaks. A choice made in Settings › This browser wins; otherwise the
 * server's own language (so a German Mac serves a German portal), then the browser's, then English.
 */

const KEY = 'goel.language'

/** "" = automatic. */
export function loadLanguage(): string {
  try {
    return localStorage.getItem(KEY) ?? ''
  } catch {
    return ''
  }
}

export function saveLanguage(code: string): void {
  try {
    if (code) localStorage.setItem(KEY, code)
    else localStorage.removeItem(KEY)
  } catch {
    // Private mode: the choice lasts this page load only.
  }
}

/** "de-AT" → "de"; unsupported or blank → null. */
function match(tag: string | null | undefined, supported: readonly string[]): string | null {
  if (!tag) return null
  const base = tag.toLowerCase().split(/[-_]/)[0] ?? ''
  return supported.includes(base) ? base : null
}

/** What "automatic" resolves to: the server's language if we have it, else the browser's first match. */
export function autoLanguage(
  server: string | null | undefined,
  browser: readonly string[],
  supported: readonly string[],
  fallback: string,
): string {
  return match(server, supported) ?? browser.map((b) => match(b, supported)).find((m) => m != null) ?? fallback
}

export function pickLanguage(
  stored: string,
  server: string | null | undefined,
  browser: readonly string[],
  supported: readonly string[],
  fallback: string,
): string {
  return match(stored, supported) ?? autoLanguage(server, browser, supported, fallback)
}

export function browserLanguages(): string[] {
  if (typeof navigator === 'undefined') return []
  return navigator.languages?.length ? [...navigator.languages] : navigator.language ? [navigator.language] : []
}
