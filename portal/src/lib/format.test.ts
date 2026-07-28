import { afterEach, describe, expect, it, vi } from 'vitest'
import en from '../locales/en.json'
import { fmtEta, fmtRate, fmtSize, fmtSpeed, fmtWhen } from './format'

afterEach(() => {
  vi.useRealTimers()
})

describe('fmtWhen', () => {
  it('takes the "Today" wording from the catalogue', () => {
    vi.useFakeTimers()
    const now = new Date('2026-07-29T15:30:00Z')
    vi.setSystemTime(now)

    const rendered = fmtWhen(Math.floor(now.getTime() / 1000))

    // The catalogue owns the word; the clock formatting stays with `toLocaleTimeString`.
    const prefix = en.format.today.replace('{{time}}', '').trim()
    expect(rendered.startsWith(prefix)).toBe(true)
    expect(rendered).not.toContain('{{time}}')
  })

  it('uses a date, not "Today", for another day', () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-07-29T15:30:00Z'))

    const earlier = new Date('2026-07-20T15:30:00Z')
    const rendered = fmtWhen(Math.floor(earlier.getTime() / 1000))

    expect(rendered).not.toContain(en.format.today.replace('{{time}}', '').trim())
  })
})

describe('byte and rate formatting is untouched by i18n', () => {
  it('formats sizes', () => {
    expect(fmtSize(null)).toBe('—')
    expect(fmtSize(0)).toBe('0 B')
    expect(fmtSize(512)).toBe('512 B')
    expect(fmtSize(1024)).toBe('1.0 KB')
    expect(fmtSize(5 * 1024 * 1024)).toBe('5.0 MB')
  })

  it('formats speeds and rates', () => {
    expect(fmtSpeed(0)).toBe('—')
    expect(fmtSpeed(2048)).toBe('2.0 KB/s')
    expect(fmtRate(0)).toBe('0 B/s')
  })

  it('formats ETAs', () => {
    expect(fmtEta(null)).toBeNull()
    expect(fmtEta(0)).toBeNull()
    expect(fmtEta(45)).toBe('45s')
    expect(fmtEta(600)).toBe('10m')
  })
})
