import { describe, expect, it } from 'vitest'
import { parseLaunch } from './launchParams'

describe('parseLaunch', () => {
  it('reads a shared url', () => {
    expect(parseLaunch('?url=https%3A%2F%2Fexample.org%2Fa.iso&title=A')).toEqual({
      links: 'https://example.org/a.iso',
      open: true,
      rest: '',
    })
  })

  it('keeps url and text apart, and a repeated link once', () => {
    expect(parseLaunch('?url=https://a.example/x&text=https://a.example/x').links).toBe('https://a.example/x')
    expect(parseLaunch('?url=https://a.example/x&text=also+https://b.example/y').links).toBe(
      'https://a.example/x\nalso https://b.example/y',
    )
  })

  it('opens an empty Add dialog for the shortcut', () => {
    expect(parseLaunch('?add=1')).toEqual({ links: '', open: true, rest: '' })
  })

  it('leaves other parameters alone and does nothing without any', () => {
    expect(parseLaunch('?token=abc&url=magnet:?xt=urn:btih:1').rest).toBe('?token=abc')
    expect(parseLaunch('')).toEqual({ links: '', open: false, rest: '' })
    expect(parseLaunch('?foo=1').open).toBe(false)
  })
})
