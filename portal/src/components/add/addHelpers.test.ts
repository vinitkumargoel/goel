import { describe, expect, it } from 'vitest'
import type { ReviewRow } from '../../lib/addReview'
import { lineHost, lineKind, reviewTypes, setChecks, shortFolder, visibleRows } from './addHelpers'

const row = (index: number, name: string, over: Partial<ReviewRow> = {}): ReviewRow => ({
  index,
  status: 'ok',
  name,
  text: `https://e/${name}`,
  kind: 'http',
  totalBytes: null,
  estimated: false,
  files: [],
  fileCount: 0,
  note: null,
  addable: true,
  ...over,
})

describe('addHelpers', () => {
  it('reads a line’s protocol and host from the text', () => {
    expect(lineKind('magnet:?xt=urn:btih:abc')).toBe('torrent')
    expect(lineKind('https://e/a.torrent')).toBe('torrent')
    expect(lineKind('sftp://h/a')).toBe('sftp')
    expect(lineKind('ftps://h/a')).toBe('ftp')
    expect(lineKind('https://h/live/master.m3u8?x=1')).toBe('hls')
    expect(lineKind('https://h/a.iso')).toBe('http')
    expect(lineHost('https://cdn.example.org/a')).toBe('cdn.example.org')
    expect(lineHost('magnet:?xt=urn:btih:abc')).toBeNull()
    expect(lineHost('nonsense')).toBeNull()
  })

  it('groups review rows by type and filters by it', () => {
    const rows = [row(0, 'a.iso'), row(1, 'b.zip'), row(2, 'c.iso')]
    expect(reviewTypes(rows)).toEqual([
      { type: 'iso', count: 2 },
      { type: 'archive', count: 1 },
    ])
    expect(visibleRows(rows, 'iso').map((r) => r.index)).toEqual([0, 2])
    expect(visibleRows(rows, 'all')).toHaveLength(3)
  })

  it('ticks only rows that can be added', () => {
    const rows = [row(0, 'a'), row(1, 'b', { addable: false }), row(2, 'c')]
    expect([...setChecks(new Set(), rows, true)]).toEqual([0, 2])
    expect([...setChecks(new Set([0, 2]), rows.slice(0, 1), false)]).toEqual([2])
  })

  it('shortens a long folder to its last two parts', () => {
    expect(shortFolder('/srv/films')).toBe('srv / films')
    expect(shortFolder('/a/b/c/d')).toBe('… / c / d')
    expect(shortFolder('/')).toBe('/')
  })
})
