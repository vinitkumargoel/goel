import { describe, expect, it } from 'vitest'
import {
  appendSample,
  EMPTY_HISTORY,
  peakRate,
  recordFrame,
  seriesPath,
  type SpeedHistory,
} from './speedHistory'
import type { TaskRow } from './types'

const row = (id: string, downSpeed: number, upSpeed = 0): TaskRow =>
  ({ id, downSpeed, upSpeed }) as TaskRow

describe('appendSample', () => {
  it('appends without touching the input', () => {
    const series = [{ down: 1, up: 0 }]
    const next = appendSample(series, { down: 2, up: 0 })
    expect(next).toEqual([
      { down: 1, up: 0 },
      { down: 2, up: 0 },
    ])
    expect(series).toHaveLength(1)
  })

  it('drops the oldest past the cap', () => {
    let series = appendSample([], { down: 0, up: 0 }, 3)
    for (let i = 1; i <= 5; i++) series = appendSample(series, { down: i, up: 0 }, 3)
    expect(series.map((s) => s.down)).toEqual([3, 4, 5])
  })
})

describe('recordFrame', () => {
  it('keeps a series per task and a summed total', () => {
    let h: SpeedHistory = EMPTY_HISTORY
    h = recordFrame(h, [row('a', 100, 10), row('b', 50)])
    h = recordFrame(h, [row('a', 200), row('b', 0, 5)])
    expect(h.perTask.get('a')?.map((s) => s.down)).toEqual([100, 200])
    expect(h.total).toEqual([
      { down: 150, up: 10 },
      { down: 200, up: 5 },
    ])
  })

  it('forgets a task that left the snapshot', () => {
    let h = recordFrame(EMPTY_HISTORY, [row('a', 1), row('b', 1)])
    h = recordFrame(h, [row('a', 2)])
    expect([...h.perTask.keys()]).toEqual(['a'])
  })

  it('stays bounded over a long session', () => {
    let h: SpeedHistory = EMPTY_HISTORY
    for (let i = 0; i < 500; i++) h = recordFrame(h, [row('a', i)], 60)
    expect(h.perTask.get('a')).toHaveLength(60)
    expect(h.total).toHaveLength(60)
    expect(h.perTask.get('a')?.at(-1)?.down).toBe(499)
  })

  it('treats a missing or negative rate as zero', () => {
    let h = recordFrame(EMPTY_HISTORY, [row('a', 5)])
    h = recordFrame(h, [{ id: 'a', downSpeed: -5 } as TaskRow])
    expect(h.perTask.get('a')).toEqual([
      { down: 5, up: 0 },
      { down: 0, up: 0 },
    ])
    expect(h.total.at(-1)).toEqual({ down: 0, up: 0 })
  })

  it('keeps no series for a task that has never moved', () => {
    const h = recordFrame(EMPTY_HISTORY, [row('idle', 0), row('busy', 3)])
    expect([...h.perTask.keys()]).toEqual(['busy'])
    expect(h.total).toEqual([{ down: 3, up: 0 }])
  })

  it('drops a series once its last non-zero sample has scrolled off', () => {
    let h = recordFrame(EMPTY_HISTORY, [row('a', 1), row('b', 1)], 3)
    // Three frames scroll the 1 off a three-slot series; the fourth finds it all zeros.
    for (let i = 0; i < 4; i++) h = recordFrame(h, [row('a', 0), row('b', 1)], 3)
    expect(h.perTask.get('a')).toBeUndefined()
    expect(h.perTask.get('b')).toHaveLength(3)
  })

  it('returns the same history for an idle frame once the total is already at rest', () => {
    const first = recordFrame(EMPTY_HISTORY, [row('a', 0)])
    expect(first.total).toEqual([{ down: 0, up: 0 }])
    expect(recordFrame(first, [row('a', 0), row('b', 0)])).toBe(first)
    // A removal still has to drop its series, idle or not.
    const moving = recordFrame(recordFrame(EMPTY_HISTORY, [row('a', 4)]), [row('a', 0)])
    expect(recordFrame(moving, [])).not.toBe(moving)
    expect(recordFrame(moving, []).perTask.size).toBe(0)
  })

  it('does not mutate the previous history', () => {
    const first = recordFrame(EMPTY_HISTORY, [row('a', 1)])
    recordFrame(first, [row('a', 2)])
    expect(first.perTask.get('a')).toHaveLength(1)
  })
})

describe('peakRate and seriesPath', () => {
  it('finds the peak over both directions', () => {
    expect(peakRate([{ down: 5, up: 9 }, { down: 7, up: 1 }])).toBe(9)
    expect(peakRate([])).toBe(0)
  })

  it('right-aligns a partly filled buffer', () => {
    const d = seriesPath([0, 10], 100, 50, 10, false, 11)
    expect(d).toBe('M90,50L100,0')
  })

  it('closes an area along the baseline', () => {
    expect(seriesPath([5], 100, 50, 10, true, 2)).toBe('M100,25L100,50L100,50Z')
  })

  it('draws a flat line at the baseline when everything is idle', () => {
    expect(seriesPath([0, 0], 10, 20, 0, false, 2)).toBe('M0,20L10,20')
    expect(seriesPath([], 10, 20, 0, false)).toBe('')
  })
})
