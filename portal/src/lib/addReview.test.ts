import { describe, expect, it } from 'vitest'
import { checkedText, initialChecks, nameFromLink, reviewRows, reviewTotals } from './addReview'
import type { AddPreviewItem } from './types'

const item = (index: number, over: Partial<AddPreviewItem> = {}): AddPreviewItem => ({
  index,
  status: 'ok',
  name: null,
  kind: 'http',
  totalBytes: null,
  estimated: false,
  files: [],
  fileCount: 0,
  note: null,
  ...over,
})

const lines = ['https://e/a.iso', 'nope', 'https://e/dup.bin', 'magnet:?xt=urn:btih:x&dn=Big+Buck%20Bunny']

describe('addReview', () => {
  const rows = reviewRows(lines, {
    items: [
      item(0, { name: 'a.iso', totalBytes: 100 }),
      item(1, { status: 'unsupported' }),
      item(2, { status: 'duplicate', totalBytes: 50 }),
      item(3, { totalBytes: 30, files: [{ name: 'f', size: 30 }], fileCount: 1 }),
    ],
    freeBytes: 120,
  })

  it('names rows from the server, else from the link', () => {
    expect(rows.map((r) => r.name)).toEqual(['a.iso', 'nope', 'dup.bin', 'Big Buck Bunny'])
  })

  it('ticks what can go, leaving duplicates and refusals off', () => {
    expect([...initialChecks(rows)]).toEqual([0, 3])
    expect(rows[1]!.addable).toBe(false)
    expect(rows[2]!.addable).toBe(true)
  })

  it('totals the ticked rows and flags a shortfall', () => {
    expect(reviewTotals(rows, new Set([0, 3]), 120)).toEqual({ count: 2, bytes: 130, unsized: 0, short: true })
    expect(reviewTotals(rows, new Set([0]), 120).short).toBe(false)
    expect(reviewTotals(rows, new Set([0, 3]), null).short).toBe(false)
  })

  it('never sends an unaddable line, even if ticked', () => {
    expect(checkedText(rows, new Set([0, 1, 3]))).toBe(`${lines[0]}\n${lines[3]}`)
  })

  it('treats a line the server left out as unchecked', () => {
    const [row] = reviewRows(['https://e/x'], { items: [], freeBytes: null })
    expect(row).toMatchObject({ status: 'unchecked', addable: true, name: 'x' })
  })

  it('falls back to the host for a bare address', () => {
    expect(nameFromLink('https://example.com/')).toBe('example.com')
  })
})
