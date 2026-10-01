/** Mirrors `TrackerList.isValidAnnounceURL` on the server, so the form can say "no" before sending. */
const SCHEMES = new Set(['udp:', 'http:', 'https:', 'ws:', 'wss:'])

/** Loopback, unspecified and link-local: the server refuses these too — no real tracker lives there. */
const LOCAL = /^(localhost|127\.|0\.0\.0\.0$|169\.254\.|\[::1?\]$|\[fe80:)/i

export function isAnnounceURL(raw: string): boolean {
  const text = raw.trim()
  if (!text || text.length > 500 || /\s/.test(text)) return false
  try {
    const url = new URL(text)
    return SCHEMES.has(url.protocol) && url.hostname !== '' && !LOCAL.test(url.hostname)
  } catch {
    return false
  }
}

/** Whitespace- or comma-separated text to the valid URLs in it (first wins, case-insensitive), plus the rejects. */
export function parseTrackers(text: string): { urls: string[]; invalid: string[] } {
  const urls: string[] = []
  const invalid: string[] = []
  const seen = new Set<string>()
  for (const token of text.split(/[\s,]+/)) {
    if (!token) continue
    if (!isAnnounceURL(token)) invalid.push(token)
    else if (!seen.has(token.toLowerCase())) {
      seen.add(token.toLowerCase())
      urls.push(token)
    }
  }
  return { urls, invalid }
}
