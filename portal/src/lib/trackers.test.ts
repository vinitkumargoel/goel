import { describe, expect, it } from 'vitest'
import { isAnnounceURL, parseTrackers } from './trackers'

describe('trackers', () => {
  it('accepts the announce schemes the server does', () => {
    for (const ok of ['udp://t.example:80/announce', 'https://t.example/announce', 'wss://t.example/x']) {
      expect(isAnnounceURL(ok)).toBe(true)
    }
    for (const bad of ['udp://127.0.0.1:80/a', 'http://localhost/a', 'udp://[::1]:6969/a', 'ftp://t.example/a', 'javascript:alert(1)', 'udp://', 'not a url', '']) {
      expect(isAnnounceURL(bad)).toBe(false)
    }
  })

  it('splits, de-duplicates and reports rejects', () => {
    expect(parseTrackers('udp://a.example/x, UDP://A.example/x\nhttp://b.example/y junk')).toEqual({
      urls: ['udp://a.example/x', 'http://b.example/y'],
      invalid: ['junk'],
    })
  })
})
