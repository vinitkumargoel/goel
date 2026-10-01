import { describe, expect, it } from 'vitest'
import {
  allTags,
  byQueuePosition,
  fromLocalInput,
  hasTag,
  MAX_TAGS,
  nextAt,
  parseRate,
  parseTags,
  rateParts,
  toLocalInput,
} from './queueControls'
import type { TaskRow } from './types'

describe('rates', () => {
  it('parses a limit in the chosen unit; blank or 0 is no limit', () => {
    expect(parseRate('2', 'MB')).toBe(2 * 1024 * 1024)
    expect(parseRate('1,5', 'MB')).toBe(1.5 * 1024 * 1024)
    expect(parseRate('500', 'KB')).toBe(500 * 1024)
    expect(parseRate('', 'KB')).toBeNull()
    expect(parseRate('0', 'MB')).toBeNull()
    expect(parseRate('-3', 'MB')).toBeUndefined()
    expect(parseRate('fast', 'MB')).toBeUndefined()
  })

  it('pre-fills in the unit that reads best', () => {
    expect(rateParts(null)).toEqual({ value: '', unit: 'MB' })
    expect(rateParts(2.5 * 1024 * 1024)).toEqual({ value: '2.5', unit: 'MB' })
    expect(rateParts(750 * 1024)).toEqual({ value: '750', unit: 'KB' })
  })
})

describe('times', () => {
  it('finds the next 01:00 still ahead', () => {
    const late = new Date(2026, 8, 30, 23, 30)
    expect(nextAt(1, late)).toEqual(new Date(2026, 9, 1, 1, 0))
    const early = new Date(2026, 8, 30, 0, 30)
    expect(nextAt(1, early)).toEqual(new Date(2026, 8, 30, 1, 0))
  })

  it('round-trips a datetime-local value and rejects junk', () => {
    const d = new Date(2026, 0, 2, 3, 4)
    expect(toLocalInput(d)).toBe('2026-01-02T03:04')
    expect(fromLocalInput('2026-01-02T03:04')).toEqual(d)
    expect(fromLocalInput('tomorrow')).toBeNull()
  })
})

describe('tags', () => {
  it('splits, trims and de-duplicates ignoring case', () => {
    expect(parseTags(' tv, Linux ,, tv , TV,\u0007x')).toEqual(['tv', 'Linux', 'x'])
  })

  it('caps the count like the server does', () => {
    const many = Array.from({ length: 40 }, (_, i) => `t${i}`).join(',')
    expect(parseTags(many)).toHaveLength(MAX_TAGS)
  })

  it('counts tags across the queue and matches case-insensitively', () => {
    const rows = [{ tags: ['tv', 'hd'] }, { tags: ['TV'] }, {}] as TaskRow[]
    expect(allTags(rows)).toEqual([
      { tag: 'tv', count: 2 },
      { tag: 'hd', count: 1 },
    ])
    expect(hasTag(rows[1]!, 'tv')).toBe(true)
    expect(hasTag(rows[2]!, 'tv')).toBe(false)
  })
})

describe('byQueuePosition', () => {
  it('orders by place in line, unplaced rows last in their list order', () => {
    const rows = [
      { id: 'a', queuePosition: null },
      { id: 'b', queuePosition: 1 },
      { id: 'c', queuePosition: 0 },
      { id: 'd' },
    ] as TaskRow[]
    expect(byQueuePosition(rows).map((r) => r.id)).toEqual(['c', 'b', 'a', 'd'])
  })
})
