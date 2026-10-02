import { describe, expect, it } from 'vitest'
import { csvCell, dateGroup, filterHistory, groupHistory, historyCSV, limitGroups } from './historyTools'
import type { HistoryRow } from './types'

const NOW = new Date(2026, 8, 30, 15, 0, 0).getTime()
const secs = (d: Date) => Math.floor(d.getTime() / 1000)

function row(id: string, name: string, kind: HistoryRow['kind'], completed: Date): HistoryRow {
  return {
    id,
    name,
    kind,
    totalBytes: 100,
    savePath: `/dl/${name}`,
    completedAt: secs(completed),
    source: `https://example.com/${name}`,
  }
}

const ROWS = [
  row('1', 'ubuntu.iso', 'http', new Date(2026, 8, 30, 9, 0)),
  row('2', 'movie.mkv', 'torrent', new Date(2026, 8, 29, 23, 59)),
  row('3', 'backup.zip', 'sftp', new Date(2026, 8, 25, 12, 0)),
  row('4', 'old.tar', 'ftp', new Date(2026, 7, 1, 12, 0)),
]

describe('filterHistory', () => {
  it('matches name or source, case-insensitively', () => {
    expect(filterHistory(ROWS, 'UBUNTU', 'all').map((r) => r.id)).toEqual(['1'])
    expect(filterHistory(ROWS, 'example.com/movie', 'all').map((r) => r.id)).toEqual(['2'])
  })

  it('filters by protocol and combines with the query', () => {
    expect(filterHistory(ROWS, '', 'torrent').map((r) => r.id)).toEqual(['2'])
    expect(filterHistory(ROWS, 'ubuntu', 'torrent')).toEqual([])
    expect(filterHistory(ROWS, '  ', 'all')).toHaveLength(4)
  })
})

describe('dateGroup and groupHistory', () => {
  it('buckets by local calendar day', () => {
    expect(dateGroup(secs(new Date(2026, 8, 30, 0, 0)), NOW)).toBe('today')
    expect(dateGroup(secs(new Date(2026, 8, 29, 23, 59)), NOW)).toBe('yesterday')
    expect(dateGroup(secs(new Date(2026, 8, 24, 0, 0)), NOW)).toBe('week')
    expect(dateGroup(secs(new Date(2026, 8, 23, 23, 59)), NOW)).toBe('older')
  })

  it('groups newest first and skips empty groups', () => {
    const groups = groupHistory([ROWS[3]!, ROWS[0]!, ROWS[2]!], NOW)
    expect(groups.map((g) => g.group)).toEqual(['today', 'week', 'older'])
    expect(groupHistory([], NOW)).toEqual([])
  })
})

describe('CSV export', () => {
  it('quotes commas, quotes and line breaks', () => {
    expect(csvCell('plain')).toBe('plain')
    expect(csvCell('a,b')).toBe('"a,b"')
    expect(csvCell('say "hi"')).toBe('"say ""hi"""')
    expect(csvCell('two\nlines')).toBe('"two\nlines"')
    expect(csvCell(null)).toBe('')
    expect(csvCell(42)).toBe('42')
  })

  it('defuses cells a spreadsheet would run as formulas', () => {
    expect(csvCell('=HYPERLINK("x")')).toBe(`"'=HYPERLINK(""x"")"`)
    expect(csvCell('+1')).toBe("'+1")
    expect(csvCell('-2')).toBe("'-2")
    expect(csvCell('@SUM(A1)')).toBe("'@SUM(A1)")
    expect(csvCell('\tcmd')).toBe("'\tcmd")
  })

  it('writes a header and one CRLF line per row', () => {
    const csv = historyCSV([ROWS[0]!])
    const lines = csv.split('\r\n')
    expect(lines[0]).toBe('Name,Protocol,Size (bytes),Completed,Saved to,Source')
    expect(lines[1]).toContain('ubuntu.iso,http,100,')
    expect(lines[1]).toContain('https://example.com/ubuntu.iso')
    expect(lines[2]).toBe('')
  })
})

describe('limitGroups', () => {
  it('cuts after the limit across groups and keeps whole groups that fit', () => {
    const groups = groupHistory(ROWS, NOW)
    const total = groups.reduce((n, g) => n + g.rows.length, 0)
    expect(limitGroups(groups, total + 5)).toEqual(groups)
    const cut = limitGroups(groups, 1)
    expect(cut).toHaveLength(1)
    expect(cut[0]!.rows).toHaveLength(1)
    expect(limitGroups(groups, 0)).toEqual([])
  })
})
