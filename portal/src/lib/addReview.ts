import type { AddPreviewItem, AddPreviewResult, AddPreviewStatus } from './types'

/** One pasted line in the Add dialog's review step. */
export interface ReviewRow extends Omit<AddPreviewItem, 'name'> {
  /** The line as typed; sent to `/api/add` when checked. */
  text: string
  /** The server's name, else the best guess from the link itself. */
  name: string
  /** Whether it can be sent at all: refused, unsupported and credential lines cannot. */
  addable: boolean
}

const ADDABLE: ReadonlySet<AddPreviewStatus> = new Set(['ok', 'unchecked', 'duplicate'])

/** A readable name for a link the server could not name: a magnet's `dn`, else the last path part. */
export function nameFromLink(text: string): string {
  if (/^magnet:/i.test(text)) {
    const dn = /[?&]dn=([^&]*)/i.exec(text)?.[1]
    if (dn) {
      try {
        return decodeURIComponent(dn.replace(/\+/g, ' '))
      } catch {
        return dn
      }
    }
    return text.slice(0, 60)
  }
  try {
    const u = new URL(text)
    const last = u.pathname.split('/').filter(Boolean).pop()
    return last ? decodeURIComponent(last) : u.host
  } catch {
    return text
  }
}

/** The review list, one row per line sent, in order. A line the server skipped reads as unchecked. */
export function reviewRows(lines: readonly string[], result: AddPreviewResult): ReviewRow[] {
  const byIndex = new Map(result.items.map((item) => [item.index, item]))
  return lines.map((text, index) => {
    const item: AddPreviewItem = byIndex.get(index) ?? {
      index,
      status: 'unchecked',
      name: null,
      kind: null,
      totalBytes: null,
      estimated: false,
      files: [],
      fileCount: 0,
      note: null,
    }
    return { ...item, text, name: item.name || nameFromLink(text), addable: ADDABLE.has(item.status) }
  })
}

/** What starts ticked: everything that can go, except what is already in the queue. */
export function initialChecks(rows: readonly ReviewRow[]): Set<number> {
  return new Set(rows.filter((r) => r.addable && r.status !== 'duplicate').map((r) => r.index))
}

export interface ReviewTotals {
  count: number
  bytes: number
  /** Ticked rows whose size is unknown: the total is a floor. */
  unsized: number
  /** The known total is more than the free space. */
  short: boolean
}

export function reviewTotals(
  rows: readonly ReviewRow[],
  checked: ReadonlySet<number>,
  freeBytes: number | null,
): ReviewTotals {
  const picked = rows.filter((r) => r.addable && checked.has(r.index))
  const bytes = picked.reduce((sum, r) => sum + (r.totalBytes ?? 0), 0)
  const unsized = picked.filter((r) => r.totalBytes == null).length
  return { count: picked.length, bytes, unsized, short: freeBytes != null && bytes > freeBytes }
}

/** The text to send: ticked lines only, one per line. */
export function checkedText(rows: readonly ReviewRow[], checked: ReadonlySet<number>): string {
  return rows
    .filter((r) => r.addable && checked.has(r.index))
    .map((r) => r.text)
    .join('\n')
}
