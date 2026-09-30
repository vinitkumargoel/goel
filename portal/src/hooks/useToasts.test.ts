import { act, renderHook } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { EXIT_MS, TOAST_MS, useToasts } from './useToasts'

beforeEach(() => {
  vi.useFakeTimers()
})

afterEach(() => {
  vi.useRealTimers()
})

function setup() {
  return renderHook(() => useToasts())
}

describe('useToasts', () => {
  it('keeps warnings well past a confirmation', () => {
    expect(TOAST_MS.warn).toBeGreaterThanOrEqual(6000)
    expect(TOAST_MS.warn).toBeGreaterThan(TOAST_MS.ok)
  })

  it('marks a toast leaving when its time is up, then removes it after the exit animation', () => {
    const { result } = setup()
    act(() => result.current.toast('Copied', 'copy'))
    expect(result.current.toasts).toHaveLength(1)

    act(() => vi.advanceTimersByTime(TOAST_MS.copy))
    expect(result.current.toasts[0]?.leaving).toBe(true)

    act(() => vi.advanceTimersByTime(EXIT_MS))
    expect(result.current.toasts).toEqual([])
  })

  it('holds a warning for its full 6 s', () => {
    const { result } = setup()
    act(() => result.current.toast('Could not reach the server', 'warn'))
    act(() => vi.advanceTimersByTime(TOAST_MS.ok + 100))
    expect(result.current.toasts[0]?.leaving).toBe(false)
    act(() => vi.advanceTimersByTime(TOAST_MS.warn - TOAST_MS.ok - 100))
    expect(result.current.toasts[0]?.leaving).toBe(true)
  })

  it('pauses while held and resumes with only the remaining time', () => {
    const { result } = setup()
    act(() => result.current.toast('Change blocked', 'warn'))
    const id = result.current.toasts[0]!.id

    act(() => vi.advanceTimersByTime(4000))
    act(() => result.current.pause(id))
    act(() => vi.advanceTimersByTime(60_000))
    expect(result.current.toasts[0]?.leaving).toBe(false)

    act(() => result.current.resume(id))
    act(() => vi.advanceTimersByTime(TOAST_MS.warn - 4000 - 1))
    expect(result.current.toasts[0]?.leaving).toBe(false)
    act(() => vi.advanceTimersByTime(1))
    expect(result.current.toasts[0]?.leaving).toBe(true)
  })

  it('dismisses early through the exit animation', () => {
    const { result } = setup()
    act(() => result.current.toast('Removed', 'trash'))
    const id = result.current.toasts[0]!.id
    act(() => result.current.dismiss(id))
    expect(result.current.toasts[0]?.leaving).toBe(true)
    act(() => vi.advanceTimersByTime(EXIT_MS))
    expect(result.current.toasts).toEqual([])
  })

  it('ignores pause, resume and dismiss for an unknown id', () => {
    const { result } = setup()
    act(() => {
      result.current.pause(99)
      result.current.resume(99)
      result.current.dismiss(99)
    })
    expect(result.current.toasts).toEqual([])
  })

  it('clears pending timers on unmount', () => {
    const { result, unmount } = setup()
    act(() => result.current.toast('Paused'))
    unmount()
    expect(vi.getTimerCount()).toBe(0)
  })
})
