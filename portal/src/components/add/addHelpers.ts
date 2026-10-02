import type { ReviewRow } from '../../lib/addReview'
import { fileType, type FileType } from '../../lib/taskKind'
import type { AddPreviewStatus, TaskKind } from '../../lib/types'

/** What a pasted line will be fetched as, from its scheme alone (the server has the last word). */
export function lineKind(text: string): TaskKind {
  if (/^magnet:/i.test(text)) return 'torrent'
  if (/^sftp:/i.test(text)) return 'sftp'
  if (/^ftps?:/i.test(text)) return 'ftp'
  if (/\.m3u8(?:[?#]|$)/i.test(text)) return 'hls'
  if (/\.torrent(?:[?#]|$)/i.test(text)) return 'torrent'
  return 'http'
}

/** The host a line points at, or null for a magnet (it has none) or an unreadable URL. */
export function lineHost(text: string): string | null {
  if (/^magnet:/i.test(text)) return null
  try {
    return new URL(text).host || null
  } catch {
    return null
  }
}

/** The Type family a review row belongs to; a magnet has no family of its own here. */
export function rowType(row: Pick<ReviewRow, 'name' | 'kind'>): Exclude<FileType, 'magnet'> {
  const type = fileType({ name: row.name, kind: row.kind ?? 'http', statusToken: '' })
  return type === 'magnet' ? 'other' : type
}

export type ReviewFilter = 'all' | Exclude<FileType, 'magnet'>

/** The review's type chips: one per family present, in first-seen order, with counts. */
export function reviewTypes(rows: readonly ReviewRow[]): { type: Exclude<FileType, 'magnet'>; count: number }[] {
  const counts = new Map<Exclude<FileType, 'magnet'>, number>()
  for (const row of rows) {
    const type = rowType(row)
    counts.set(type, (counts.get(type) ?? 0) + 1)
  }
  return [...counts].map(([type, count]) => ({ type, count }))
}

export function visibleRows(rows: readonly ReviewRow[], filter: ReviewFilter): ReviewRow[] {
  return filter === 'all' ? [...rows] : rows.filter((r) => rowType(r) === filter)
}

/** Ticks (or clears) every addable row in `rows`, leaving the others as they were. */
export function setChecks(checked: ReadonlySet<number>, rows: readonly ReviewRow[], on: boolean): Set<number> {
  const next = new Set(checked)
  for (const row of rows) {
    if (!row.addable) continue
    if (on) next.add(row.index)
    else next.delete(row.index)
  }
  return next
}

/** The `.pill` a review status is drawn as. */
export const STATUS_PILL: Readonly<Record<AddPreviewStatus, string>> = {
  ok: 'pill good',
  unchecked: 'pill nodot',
  duplicate: 'pill',
  credentials: 'pill warn',
  unsupported: 'pill bad',
  refused: 'pill bad',
}

/** A recent folder as a chip: its last two parts, the full path in the title. */
export function shortFolder(path: string): string {
  const parts = path.split('/').filter(Boolean)
  return parts.length <= 2 ? parts.join(' / ') || path : `… / ${parts.slice(-2).join(' / ')}`
}

/** ⌘↩ on Apple keyboards, Ctrl ↩ elsewhere: the key that submits the Add dialog. */
export function submitKeys(): string {
  const platform = typeof navigator === 'undefined' ? '' : navigator.platform
  return /Mac|iPhone|iPad|iPod/.test(platform) ? '⌘↩' : 'Ctrl ↩'
}
