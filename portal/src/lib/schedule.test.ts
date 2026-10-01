import { describe, expect, it } from 'vitest'
import { cellOpen, fmtMinute, isOpenAt, paintRange, profileColor, toggleDay } from './schedule'

const ALL = [1, 2, 3, 4, 5, 6, 7]

describe('isOpenAt mirrors the scheduler', () => {
  it('is always open when start equals end, whatever the days', () => {
    expect(isOpenAt({ startMinute: 60, endMinute: 60, days: [2] }, 4, 900)).toBe(true)
  })

  it('opens a same-day window only on its days', () => {
    const w = { startMinute: 9 * 60, endMinute: 17 * 60, days: [2] }
    expect(isOpenAt(w, 2, 9 * 60)).toBe(true)
    expect(isOpenAt(w, 2, 17 * 60)).toBe(false)
    expect(isOpenAt(w, 3, 10 * 60)).toBe(false)
  })

  it('gives the after-midnight part of a wrapping window to the previous day', () => {
    const w = { startMinute: 22 * 60, endMinute: 7 * 60, days: [6] } // Friday night
    expect(isOpenAt(w, 6, 23 * 60)).toBe(true)
    expect(isOpenAt(w, 7, 3 * 60)).toBe(true) // Saturday 03:00 is Friday's window
    expect(isOpenAt(w, 6, 3 * 60)).toBe(false)
    expect(isOpenAt({ ...w, days: [7] }, 1, 60)).toBe(true) // Sunday 01:00 belongs to Saturday
  })
})

describe('grid', () => {
  it('paints an hour touched by a half-hour boundary', () => {
    const w = { startMinute: 22 * 60 + 30, endMinute: 23 * 60 + 30, days: ALL }
    expect(cellOpen(w, 3, 22)).toBe(true)
    expect(cellOpen(w, 3, 23)).toBe(true)
    expect(cellOpen(w, 3, 21)).toBe(false)
  })

  it('paints a contiguous range in either drag direction, ending at midnight as 0', () => {
    expect(paintRange(9, 16)).toEqual({ startMinute: 540, endMinute: 1020 })
    expect(paintRange(16, 9)).toEqual({ startMinute: 540, endMinute: 1020 })
    expect(paintRange(20, 23)).toEqual({ startMinute: 1200, endMinute: 0 })
  })

  it('never removes the last day', () => {
    expect(toggleDay([2], 2)).toEqual([2])
    expect(toggleDay([2, 3], 2)).toEqual([3])
    expect(toggleDay([3], 1)).toEqual([1, 3])
  })

  it('formats minutes and colours profiles stably', () => {
    expect(fmtMinute(0)).toBe('00:00')
    expect(fmtMinute(1439)).toBe('23:59')
    expect(profileColor('Night', ['Low', 'Night'])).toBe(profileColor('Night', ['Low', 'Night']))
    expect(profileColor('', [])).toBe('var(--accent)')
  })
})
