import { afterEach, describe, expect, it, vi } from 'vitest'
import i18n from '../i18n'
import en from '../locales/en.json'
import {
  fmtAgo,
  fmtClock,
  fmtEta,
  fmtNumber,
  fmtPercent,
  fmtShortWhen,
  fmtProgressSize,
  fmtSize,
  fmtSpeed,
  fmtWhen,
  IDLE_RATE,
} from './format'

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
    expect(fmtSpeed(0, IDLE_RATE)).toBe('0 B/s')
    expect(fmtSpeed(2048, IDLE_RATE)).toBe('2.0 KB/s')
    expect(fmtSpeed(0, '')).toBe('')
  })

  it('formats ETAs', () => {
    expect(fmtEta(null)).toBeNull()
    expect(fmtEta(0)).toBeNull()
    expect(fmtEta(45)).toBe('45s')
    expect(fmtEta(600)).toBe('10m')
  })
})

describe('relative and clock times', () => {
  const now = Date.UTC(2026, 8, 30, 12, 0, 0)
  const ago = (s: number) => now / 1000 - s

  it('says how long ago, coarsening with age', () => {
    expect(fmtAgo(ago(20), now)).toBe('just now')
    expect(fmtAgo(ago(5 * 60), now)).toBe('5m ago')
    expect(fmtAgo(ago(2 * 3600 + 59), now)).toBe('2h ago')
    expect(fmtAgo(ago(3 * 86400), now)).toBe('3d ago')
    expect(fmtAgo(ago(60 * 86400), now)).not.toMatch(/ago/)
  })

  it('never reads a future time as negative', () => {
    expect(fmtAgo(now / 1000 + 90, now)).toBe('just now')
  })

  it('formats elapsed seconds as a clock', () => {
    expect(fmtClock(14)).toBe('0:14')
    expect(fmtClock(125.9)).toBe('2:05')
    expect(fmtClock(3725)).toBe('1:02:05')
    expect(fmtClock(-3)).toBe('0:00')
  })

  it('shares the unit in done/total when it can', () => {
    const GB = 1024 ** 3
    expect(fmtProgressSize(2.9 * GB, 4.7 * GB)).toBe('2.9/4.7 GB')
    expect(fmtProgressSize(900 * 1024 ** 2, 4.7 * GB)).toBe('900 MB/4.7 GB')
    expect(fmtProgressSize(1024, null)).toBe('1.0 KB')
  })
})

describe('formatting follows the chosen language', () => {
  afterEach(() => i18n.changeLanguage('en'))

  it('uses the language\'s decimal separator for sizes, percents and ratios', async () => {
    await i18n.changeLanguage('de')
    expect(fmtSize(1536)).toBe('1,5 KB')
    expect(fmtNumber(1.25, 2)).toBe('1,25')
    expect(fmtPercent(0.42).replace(/\s/g, '')).toBe('42%')
    expect(fmtProgressSize(2.9 * 1024 ** 3, 4.7 * 1024 ** 3)).toBe('2,9/4,7 GB')
    await i18n.changeLanguage('en')
    expect(fmtSize(1536)).toBe('1.5 KB')
  })

  it('writes ETA units from the catalogue', async () => {
    await i18n.changeLanguage('de')
    expect(fmtEta(45)).toBe('45 s')
    expect(fmtEta(600)).toBe('10 Min.')
    expect(fmtEta(3725)).toBe('1 Std. 2 Min.')
    expect(fmtEta(2 * 86400)).toBe('2 T')
  })

  it('formats dates in the chosen language, not the browser\'s', async () => {
    const now = Date.UTC(2026, 8, 30, 12, 0, 0)
    const older = now / 1000 - 3 * 86400
    await i18n.changeLanguage('de')
    expect(fmtShortWhen(older, now)).toMatch(/Sept?\./)
    await i18n.changeLanguage('en')
    expect(fmtShortWhen(older, now)).toMatch(/Sep/)
  })
})
