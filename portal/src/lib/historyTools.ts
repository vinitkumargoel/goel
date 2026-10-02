import i18n from '../i18n'
import type { HistoryRow, TaskKind } from './types'

export type KindFilter = TaskKind | 'all'

/** Rows whose name or source contains `query` (case-insensitive) and whose protocol matches. */
export function filterHistory(
  rows: readonly HistoryRow[],
  query: string,
  kind: KindFilter,
): HistoryRow[] {
  const q = query.trim().toLowerCase()
  return rows.filter(
    (r) =>
      (kind === 'all' || r.kind === kind) &&
      (q === '' || r.name.toLowerCase().includes(q) || r.source.toLowerCase().includes(q)),
  )
}

export type DateGroup = 'today' | 'yesterday' | 'week' | 'older'

export const DATE_GROUPS: readonly DateGroup[] = ['today', 'yesterday', 'week', 'older']

function startOfDay(ms: number): number {
  const d = new Date(ms)
  d.setHours(0, 0, 0, 0)
  return d.getTime()
}

/** Local calendar buckets: today, yesterday, the five days before that, and everything older. */
export function dateGroup(unixSeconds: number, nowMs: number = Date.now()): DateGroup {
  const today = startOfDay(nowMs)
  const at = unixSeconds * 1000
  if (at >= today) return 'today'
  const yesterday = startOfDay(today - 1)
  if (at >= yesterday) return 'yesterday'
  const weekStart = startOfDay(today - 6 * 86_400_000)
  if (at >= weekStart) return 'week'
  return 'older'
}

export interface HistoryGroup {
  group: DateGroup
  rows: HistoryRow[]
}

/** Newest first within the fixed group order; empty groups are left out. */
export function groupHistory(rows: readonly HistoryRow[], nowMs: number = Date.now()): HistoryGroup[] {
  const buckets = new Map<DateGroup, HistoryRow[]>(DATE_GROUPS.map((g) => [g, []]))
  const sorted = [...rows].sort((a, b) => b.completedAt - a.completedAt)
  for (const row of sorted) buckets.get(dateGroup(row.completedAt, nowMs))!.push(row)
  return DATE_GROUPS.map((group) => ({ group, rows: buckets.get(group)! })).filter(
    (g) => g.rows.length > 0,
  )
}

/** The groups cut after `limit` rows in all, for incremental rendering; whole groups when they fit. */
export function limitGroups(groups: readonly HistoryGroup[], limit: number): HistoryGroup[] {
  let left = limit
  const out: HistoryGroup[] = []
  for (const g of groups) {
    if (left <= 0) break
    out.push(g.rows.length <= left ? g : { ...g, rows: g.rows.slice(0, left) })
    left -= g.rows.length
  }
  return out
}

/**
 * One CSV cell. A value a spreadsheet would run as a formula (leading = + - @, or a tab/CR that
 * some apps strip first) is prefixed with `'`; anything with a quote, comma or line break is quoted.
 */
export function csvCell(value: string | number | null | undefined): string {
  let s = value == null ? '' : String(value)
  if (/^[=+\-@\t\r]/.test(s)) s = `'${s}`
  if (/[",\r\n]/.test(s)) s = `"${s.replace(/"/g, '""')}"`
  return s
}

/** The column titles in the chosen language; the values (ISO dates, raw bytes) stay machine-readable. */
export function csvHeader(): string[] {
  return [
    i18n.t('history.csv.name'),
    i18n.t('history.csv.protocol'),
    i18n.t('history.csv.size'),
    i18n.t('history.csv.completed'),
    i18n.t('history.csv.savedTo'),
    i18n.t('history.csv.source'),
  ]
}

/** RFC 4180 CSV (CRLF line ends) of the given rows; completion times are ISO 8601 in UTC. */
export function historyCSV(rows: readonly HistoryRow[]): string {
  const lines = [csvHeader().map(csvCell).join(',')]
  for (const r of rows) {
    lines.push(
      [
        r.name,
        r.kind,
        r.totalBytes ?? '',
        new Date(r.completedAt * 1000).toISOString(),
        r.savePath,
        r.source,
      ]
        .map(csvCell)
        .join(','),
    )
  }
  return lines.join('\r\n') + '\r\n'
}
