import i18n from '../i18n'

/** The language the user chose (not the browser's): every number and date follows it. */
export function locale(): string {
  return i18n.language || 'en'
}

const numberFormats = new Map<string, Intl.NumberFormat>()

/** A number with `digits` decimals in the chosen language's separators ("1.5" / "1,5"). */
export function fmtNumber(n: number, digits = 0): string {
  const key = `${locale()}:${digits}`
  let f = numberFormats.get(key)
  if (!f) {
    f = new Intl.NumberFormat(locale(), { minimumFractionDigits: digits, maximumFractionDigits: digits })
    numberFormats.set(key, f)
  }
  return f.format(n)
}

/** A 0..1 fraction as a whole percent: "42%" / "42 %" as the language writes it. */
export function fmtPercent(fraction: number): string {
  return new Intl.NumberFormat(locale(), { style: 'percent', maximumFractionDigits: 0 }).format(fraction)
}

/** The clock time, 24 or 12 hour as the language does it. */
export function fmtClockTime(d: Date): string {
  return d.toLocaleTimeString(locale(), { hour: '2-digit', minute: '2-digit' })
}

/** A short weekday name in the chosen language. */
export function fmtWeekday(d: Date): string {
  return d.toLocaleDateString(locale(), { weekday: 'short' })
}

// Byte units and the ↓/↑ glyphs stay literal: they are symbols, not prose, and are
// written the same way in every locale this app targets.
export function fmtSize(bytes: number | null | undefined): string {
  if (bytes == null) return '—'
  if (bytes < 1) return '0 B'
  if (bytes < 1024) return `${fmtNumber(Math.round(bytes))} B`
  const units = ['KB', 'MB', 'GB', 'TB']
  let n = bytes
  let i = -1
  do {
    n /= 1024
    i++
  } while (n >= 1024 && i < units.length - 1)
  return `${fmtNumber(n, n < 10 ? 1 : 0)} ${units[i]}`
}

/**
 * A transfer rate. `idle` is what a zero or unknown rate reads as: a table cell wants a dash (or
 * nothing), while the always-visible totals in the top and status bars want a figure, `IDLE_RATE`.
 */
export function fmtSpeed(bytesPerSecond: number | null | undefined, idle = '—'): string {
  return bytesPerSecond != null && bytesPerSecond > 0 ? `${fmtSize(bytesPerSecond)}/s` : idle
}

export const IDLE_RATE = '0 B/s'

export function fmtEta(seconds: number | null | undefined): string | null {
  if (seconds == null || seconds <= 0 || !isFinite(seconds)) return null
  const s = Math.round(seconds)
  if (s < 60) return i18n.t('format.eta.seconds', { n: s })
  if (s < 3600) return i18n.t('format.eta.minutes', { n: Math.floor(s / 60) })
  if (s < 86400) return i18n.t('format.eta.hours', { h: Math.floor(s / 3600), m: Math.floor((s % 3600) / 60) })
  return i18n.t('format.eta.days', { n: Math.floor(s / 86400) })
}

export function fmtWhen(unixSeconds: number): string {
  const d = new Date(unixSeconds * 1000)
  const now = new Date()
  const time = fmtClockTime(d)
  if (d.toDateString() === now.toDateString()) return i18n.t('format.today', { time })
  return `${d.toLocaleDateString(locale(), { month: 'short', day: 'numeric' })} ${time}`
}

/** For narrow rows: a time today, "Sep 29" this year, then with the year. `fmtAbsolute` goes in the tooltip. */
export function fmtShortWhen(unixSeconds: number, nowMs: number = Date.now()): string {
  const d = new Date(unixSeconds * 1000)
  const now = new Date(nowMs)
  if (d.toDateString() === now.toDateString()) {
    return fmtClockTime(d)
  }
  if (d.getFullYear() === now.getFullYear()) {
    return d.toLocaleDateString(locale(), { month: 'short', day: 'numeric' })
  }
  return d.toLocaleDateString(locale(), { year: 'numeric', month: 'short', day: 'numeric' })
}

export function pct(fraction: number): number {
  return fraction * 100
}

/** A compact relative time for a list cell — "just now", "5m ago", "2h ago", "3d ago", then a date. */
export function fmtAgo(unixSeconds: number, nowMs: number = Date.now()): string {
  const diff = Math.max(0, Math.floor(nowMs / 1000 - unixSeconds))
  if (diff < 60) return i18n.t('format.justNow')
  if (diff < 3600) return i18n.t('format.minutesAgo', { count: Math.floor(diff / 60) })
  if (diff < 86400) return i18n.t('format.hoursAgo', { count: Math.floor(diff / 3600) })
  if (diff < 86400 * 30) return i18n.t('format.daysAgo', { count: Math.floor(diff / 86400) })
  return new Date(unixSeconds * 1000).toLocaleDateString(locale(), { month: 'short', day: 'numeric' })
}

/** The full local date and time, for a tooltip behind a relative time. */
export function fmtAbsolute(unixSeconds: number): string {
  return new Date(unixSeconds * 1000).toLocaleString(locale(), {
    year: 'numeric',
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit',
  })
}

/** An elapsed duration as a clock: 14 → "0:14", 125 → "2:05", 3725 → "1:02:05". */
export function fmtClock(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds))
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  const ss = String(s % 60).padStart(2, '0')
  return h > 0 ? `${h}:${String(m).padStart(2, '0')}:${ss}` : `${m}:${ss}`
}

/** "2.9/4.7 GB" when both share a unit, "900 MB/4.7 GB" when not, only the done part when the total is unknown. */
export function fmtProgressSize(done: number, total: number | null): string {
  const d = fmtSize(done)
  if (total == null) return d
  const t = fmtSize(total)
  const [dn, du] = d.split(' ')
  const tu = t.split(' ')[1]
  return du === tu ? `${dn}/${t}` : `${d}/${t}`
}
