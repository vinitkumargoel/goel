import { describe, expect, it } from 'vitest'
import type { HistoryRow } from '../../lib/types'
import { countOlderThan, csvFileName, entryTime, folderOf, hostOf, monthSummary } from './historyParts'

const NOW = new Date(2026, 9, 15, 12, 0).getTime()
const at = (y: number, m: number, d: number, h = 9, min = 30) => new Date(y, m, d, h, min).getTime() / 1000

const row = (id: string, name: string, completedAt: number, totalBytes: number | null = 100): HistoryRow => ({
  id,
  name,
  kind: 'http',
  totalBytes,
  savePath: `/dl/stuff/${name}`,
  completedAt,
  source: `https://files.example.com/${name}`,
})

describe('historyParts', () => {
  it('reads the host of a URL and nothing of a magnet', () => {
    expect(hostOf('https://releases.ubuntu.com/x.iso')).toBe('releases.ubuntu.com')
    expect(hostOf('http://nas.home:8080/a')).toBe('nas.home:8080')
    expect(hostOf('magnet:?xt=urn:btih:abc')).toBe('')
    expect(hostOf('not a url')).toBe('')
  })

  it('takes the folder from a save path that ends in the file name', () => {
    expect(folderOf('/Users/me/Downloads/Movies/a.mkv')).toBe('Movies')
    expect(folderOf('a.mkv')).toBe('')
  })

  it('names the CSV by date', () => {
    expect(csvFileName(Date.UTC(2026, 9, 2, 8))).toBe('goel-history-2026-10-02.csv')
  })

  it('shows a clock today and yesterday, a weekday this week, a date before that', () => {
    const t = at(2026, 9, 15, 9, 5)
    const clock = new Date(t * 1000).toLocaleTimeString('en', { hour: '2-digit', minute: '2-digit' })
    expect(entryTime(t, 'today', NOW)).toBe(clock)
    expect(entryTime(t, 'yesterday', NOW)).toBe(clock)
    expect(entryTime(t, 'week', NOW)).toContain(clock)
    expect(entryTime(t, 'week', NOW)).not.toBe(clock)
    expect(entryTime(at(2026, 1, 3), 'older', NOW)).not.toContain(':')
  })

  it('totals the current month by file type, largest first', () => {
    const rows = [
      row('1', 'a.iso', at(2026, 9, 2), 500),
      row('2', 'b.mkv', at(2026, 9, 10), 900),
      row('3', 'c.mkv', at(2026, 9, 11), null),
      row('4', 'old.iso', at(2026, 8, 30), 10_000),
    ]
    const s = monthSummary(rows, NOW)
    expect(s.count).toBe(3)
    expect(s.bytes).toBe(1400)
    expect(s.byType).toEqual([
      { type: 'video', bytes: 900, count: 2 },
      { type: 'iso', bytes: 500, count: 1 },
    ])
    expect(monthSummary([], NOW)).toEqual({ count: 0, bytes: 0, byType: [] })
  })

  it('counts what "clear older than" would take, or everything', () => {
    const rows = [row('1', 'a', NOW / 1000 - 2 * 86400), row('2', 'b', NOW / 1000 - 10 * 86400)]
    expect(countOlderThan(rows, 7, NOW)).toBe(1)
    expect(countOlderThan(rows, 30, NOW)).toBe(0)
    expect(countOlderThan(rows, null, NOW)).toBe(2)
  })
})
