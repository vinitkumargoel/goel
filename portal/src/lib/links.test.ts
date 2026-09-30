import { describe, expect, it } from 'vitest'
import { summarizeLinks } from './links'

describe('summarizeLinks', () => {
  it('counts one link per non-blank line', () => {
    const s = summarizeLinks(
      'https://example.com/a.iso\n\n  magnet:?xt=urn:btih:abc  \r\nsftp://me@host/f.zip\rftp://h/x',
    )
    expect(s.valid).toBe(4)
    expect(s.unsupported).toEqual([])
    expect(s.lines.map((l) => l.text)[1]).toBe('magnet:?xt=urn:btih:abc')
  })

  it('flags lines that are not http(s), ftp, sftp or magnet links', () => {
    const s = summarizeLinks('http://ok.example/f\nexample.com/file.iso\nfile:///etc/passwd\nmagnet:')
    expect(s.valid).toBe(1)
    expect(s.unsupported.map((l) => l.text)).toEqual([
      'example.com/file.iso',
      'file:///etc/passwd',
      'magnet:',
    ])
  })

  it('accepts schemes in any case', () => {
    expect(summarizeLinks('HTTPS://EXAMPLE.COM/A').valid).toBe(1)
  })

  it('is empty for blank input', () => {
    expect(summarizeLinks('  \n \n')).toEqual({ lines: [], valid: 0, unsupported: [] })
  })
})
