import { describe, expect, it } from 'vitest'
import { isTorrentFile, MAX_TORRENT_BYTES, MAX_TORRENT_FILES, mergeTorrents } from './torrentFiles'

const file = (name: string, size = 10, type = '') => {
  const f = new File(['x'], name, { type, lastModified: 1 })
  Object.defineProperty(f, 'size', { value: size })
  return f
}

describe('isTorrentFile', () => {
  it('goes by extension or MIME type', () => {
    expect(isTorrentFile(file('a.TORRENT'))).toBe(true)
    expect(isTorrentFile(file('blob', 1, 'application/x-bittorrent'))).toBe(true)
    expect(isTorrentFile(file('a.iso'))).toBe(false)
  })
})

describe('mergeTorrents', () => {
  it('adds torrents and reports why others were refused', () => {
    const out = mergeTorrents([], [
      file('a.torrent'),
      file('b.iso'),
      file('big.torrent', MAX_TORRENT_BYTES + 1),
    ])
    expect(out.files.map((f) => f.name)).toEqual(['a.torrent'])
    expect(out.rejected).toEqual([
      { name: 'b.iso', reason: 'notTorrent' },
      { name: 'big.torrent', reason: 'tooLarge' },
    ])
  })

  it('skips a file already in the list', () => {
    const a = file('a.torrent')
    const out = mergeTorrents([a], [file('a.torrent')])
    expect(out.files).toEqual([a])
    expect(out.rejected[0]?.reason).toBe('duplicate')
  })

  it('stops at the file cap without mutating the input', () => {
    const current = Array.from({ length: MAX_TORRENT_FILES }, (_, i) => file(`${i}.torrent`))
    const out = mergeTorrents(current, [file('one-more.torrent')])
    expect(out.files).toHaveLength(MAX_TORRENT_FILES)
    expect(out.rejected[0]?.reason).toBe('tooMany')
    expect(current).toHaveLength(MAX_TORRENT_FILES)
  })
  it('stops once the combined size would pass 25 MB', () => {
    const nine = 9 * 1024 * 1024
    const out = mergeTorrents([], [file('a.torrent', nine), file('b.torrent', nine), file('c.torrent', nine)])
    expect(out.files.map((f) => f.name)).toEqual(['a.torrent', 'b.torrent'])
    expect(out.rejected).toEqual([{ name: 'c.torrent', reason: 'totalTooLarge' }])
  })
})
