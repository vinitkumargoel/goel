import { describe, expect, it } from 'vitest'
import { fileType, KIND_BADGE, KIND_LABEL, kindBadge, kindLabel } from './taskKind'

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

describe('fileType', () => {
  const type = (name: string, kind: 'http' | 'torrent' | 'hls' = 'http', statusToken: 'downloading' | 'metadata' = 'downloading') =>
    fileType({ name, kind, statusToken })

  it('sorts names into the same types as the Mac app', () => {
    expect(type('Movie.2024.MKV')).toBe('video')
    expect(type('album.flac')).toBe('audio')
    expect(type('photo.HEIC')).toBe('image')
    expect(type('ubuntu.iso')).toBe('iso')
    expect(type('backup.tar.zst')).toBe('archive')
    expect(type('Tool.pkg')).toBe('app')
    expect(type('notes.pdf')).toBe('doc')
    expect(type('README')).toBe('other')
  })

  it('files a disk image with archives, as the Mac app does', () => {
    expect(type('Installer.dmg')).toBe('archive')
  })

  it('treats streams and bare torrents as video, and a magnet still fetching metadata as a magnet', () => {
    expect(type('live', 'hls')).toBe('video')
    expect(type('Some Season Pack', 'torrent')).toBe('video')
    expect(type('Some Season Pack', 'torrent', 'metadata')).toBe('magnet')
  })
})
