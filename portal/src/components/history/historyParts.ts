import { fmtClockTime, fmtShortWhen, fmtWeekday } from '../../lib/format'
import type { DateGroup } from '../../lib/historyTools'
import { fileType, type FileType } from '../../lib/taskKind'
import type { HistoryRow } from '../../lib/types'

export const DAY = 86_400

/** Hands the browser a file to save. A no-op where object URLs are missing (jsdom). */
export function saveFile(name: string, text: string, type: string): void {
  if (typeof URL.createObjectURL !== 'function') return
  const url = URL.createObjectURL(new Blob([text], { type }))
  const a = document.createElement('a')
  a.href = url
  a.download = name
  a.rel = 'noopener'
  document.body.append(a)
  a.click()
  a.remove()
  setTimeout(() => URL.revokeObjectURL(url), 0)
}

/** `goel-history-2026-10-02.csv`, dated in UTC like the CSV's own timestamps. */
export function csvFileName(nowMs: number = Date.now()): string {
  return `goel-history-${new Date(nowMs).toISOString().slice(0, 10)}.csv`
}

/** The source's host for the meta line; '' for a magnet or anything that isn't a URL. */
export function hostOf(source: string): string {
  try {
    return new URL(source).host
  } catch {
    return ''
  }
}

/** `savePath` includes the file name, so the folder is the second-to-last component, not the last. */
export function folderOf(savePath: string): string {
  const parts = savePath.split('/').filter(Boolean)
  return parts.length >= 2 ? parts[parts.length - 2]! : ''
}

export function entryType(e: Pick<HistoryRow, 'name' | 'kind'>): FileType {
  return fileType({ name: e.name, kind: e.kind, statusToken: '' })
}

/**
 * The time beside an entry. Its date group already says the day, so today and yesterday show a
 * clock, this week a weekday and clock, and anything older a short date.
 */
export function entryTime(completedAt: number, group: DateGroup, nowMs: number = Date.now()): string {
  const d = new Date(completedAt * 1000)
  const clock = fmtClockTime(d)
  if (group === 'today' || group === 'yesterday') return clock
  if (group === 'week') return `${fmtWeekday(d)} ${clock}`
  return fmtShortWhen(completedAt, nowMs)
}

export interface TypeTotal {
  type: FileType
  bytes: number
  count: number
}

export interface MonthSummary {
  count: number
  bytes: number
  /** Largest first; types with nothing this month are left out. */
  byType: TypeTotal[]
}

/** What finished in the current calendar month (local time), totalled by file type. */
export function monthSummary(rows: readonly HistoryRow[], nowMs: number = Date.now()): MonthSummary {
  const now = new Date(nowMs)
  const start = new Date(now.getFullYear(), now.getMonth(), 1).getTime() / 1000
  const totals = new Map<FileType, TypeTotal>()
  let count = 0
  let bytes = 0
  for (const r of rows) {
    if (r.completedAt < start) continue
    const size = r.totalBytes ?? 0
    count += 1
    bytes += size
    const type = entryType(r)
    const prev = totals.get(type) ?? { type, bytes: 0, count: 0 }
    totals.set(type, { type, bytes: prev.bytes + size, count: prev.count + 1 })
  }
  const byType = [...totals.values()].sort((a, b) => b.bytes - a.bytes || b.count - a.count)
  return { count, bytes, byType }
}

/** How many rows "Clear older than" would take: all of them for `null`. */
export function countOlderThan(rows: readonly HistoryRow[], days: number | null, nowMs: number = Date.now()): number {
  const cutoff = days == null ? Infinity : nowMs / 1000 - days * DAY
  return rows.filter((r) => r.completedAt < cutoff).length
}
