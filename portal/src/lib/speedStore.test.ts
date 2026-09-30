import { act, renderHook } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import { SpeedStore, useSpeedSeries } from './speedStore'
import type { TaskRow } from './types'

const row = (id: string, downSpeed: number): TaskRow => ({ id, downSpeed, upSpeed: 0 }) as TaskRow

describe('SpeedStore', () => {
  it('notifies only when a frame changes the history', () => {
    const store = new SpeedStore()
    const listener = vi.fn()
    const unsubscribe = store.subscribe(listener)
    store.record([row('a', 0)])
    expect(listener).toHaveBeenCalledTimes(1)
    store.record([row('a', 0)])
    expect(listener).toHaveBeenCalledTimes(1)
    store.record([row('a', 7)])
    expect(listener).toHaveBeenCalledTimes(2)
    unsubscribe()
    store.record([row('a', 8)])
    expect(listener).toHaveBeenCalledTimes(2)
  })
})

describe('useSpeedSeries', () => {
  it('re-renders for its own series only', () => {
    const store = new SpeedStore()
    let renders = 0
    const { result } = renderHook(() => {
      renders++
      return useSpeedSeries('a', store)
    })
    const empty = result.current
    expect(empty).toEqual([])
    const before = renders
    // Another task moving leaves the idle 'a' untracked: its series stays the same empty array.
    act(() => store.record([row('a', 0), row('b', 5)]))
    act(() => store.record([row('a', 0), row('b', 6)]))
    expect(result.current).toBe(empty)
    expect(renders).toBe(before)
    act(() => store.record([row('a', 5), row('b', 6)]))
    expect(result.current).toEqual([{ down: 5, up: 0 }])
  })

  it("reads the summed rates as 'total'", () => {
    const store = new SpeedStore()
    const { result } = renderHook(() => useSpeedSeries('total', store))
    act(() => store.record([row('a', 2), row('b', 3)]))
    expect(result.current).toEqual([{ down: 5, up: 0 }])
  })
})
