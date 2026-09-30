import { describe, expect, it } from 'vitest'
import { KIND_BADGE, KIND_LABEL, kindBadge, kindLabel } from './taskKind'

describe('kindBadge', () => {
  it('uses the Mac app’s short forms', () => {
    expect(kindBadge('torrent')).toBe('BT')
    expect(kindBadge('http')).toBe('HTTP')
    expect(kindBadge('ftp')).toBe('FTP')
    expect(kindBadge('sftp')).toBe('SFTP')
    expect(kindBadge('hls')).toBe('HLS')
  })

  it('covers every kind the long-form map covers', () => {
    expect(Object.keys(KIND_BADGE).sort()).toEqual(Object.keys(KIND_LABEL).sort())
  })

  it('upper-cases an unknown kind rather than dropping it', () => {
    expect(kindBadge('ed2k')).toBe('ED2K')
  })

  it('leaves the long form for detail subtitles', () => {
    expect(kindLabel('torrent')).toBe('BitTorrent')
  })
})
