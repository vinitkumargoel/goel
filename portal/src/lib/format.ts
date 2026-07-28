/** Display formatters. Ported from the hand-written portal JS with the same rounding behaviour, so
 * the numbers on screen do not shift under users who knew the old build. */

/** Binary units, matching the desktop app. `null` renders as an em dash. */
export function fmtSize(bytes: number | null | undefined): string {
  if (bytes == null) return '—'
  if (bytes < 1) return '0 B'
  if (bytes < 1024) return `${Math.round(bytes)} B`
  const units = ['KB', 'MB', 'GB', 'TB']
  let n = bytes
  let i = -1
  do {
    n /= 1024
    i++
  } while (n >= 1024 && i < units.length - 1)
  // One decimal below 10 so "1.4 GB" doesn't collapse to a uselessly coarse "1 GB".
  return `${n.toFixed(n < 10 ? 1 : 0)} ${units[i]}`
}

/** Zero and negative rates render as an em dash, not "0 B/s". */
export function fmtSpeed(bytesPerSecond: number | null | undefined): string {
  return bytesPerSecond != null && bytesPerSecond > 0 ? `${fmtSize(bytesPerSecond)}/s` : '—'
}

/** The topbar totals want a real zero rather than a dash. */
export function fmtRate(bytesPerSecond: number): string {
  const s = fmtSpeed(bytesPerSecond)
  return s === '—' ? '0 B/s' : s
}

/** Null for "no meaningful estimate" so callers can omit the row entirely. */
export function fmtEta(seconds: number | null | undefined): string | null {
  if (seconds == null || seconds <= 0 || !isFinite(seconds)) return null
  const s = Math.round(seconds)
  if (s < 60) return `${s}s`
  if (s < 3600) return `${Math.floor(s / 60)}m`
  if (s < 86400) return `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m`
  return `${Math.floor(s / 86400)}d`
}

/** Unix seconds → "Today 14:03" or "12 Mar 14:03". */
export function fmtWhen(unixSeconds: number): string {
  const d = new Date(unixSeconds * 1000)
  const now = new Date()
  const time = d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
  if (d.toDateString() === now.toDateString()) return `Today ${time}`
  return `${d.toLocaleDateString([], { month: 'short', day: 'numeric' })} ${time}`
}

export function pct(fraction: number): number {
  return fraction * 100
}
