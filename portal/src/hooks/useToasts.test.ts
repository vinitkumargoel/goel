import { act, renderHook } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { DEDUPE_MS, EXIT_MS, MAX_TOASTS, TOAST_MS, UNDO_MS, useToasts } from './useToasts'

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

  it('collapses an identical toast fired moments later into one, restarting its clock', () => {
    const { result } = setup()
    act(() => result.current.toast('Change blocked', 'warn'))
    act(() => vi.advanceTimersByTime(1000))
    act(() => {
      result.current.toast('Change blocked', 'warn')
      result.current.toast('Change blocked', 'warn')
    })
    expect(result.current.toasts).toHaveLength(1)

    // The clock restarted at the repeat, so it outlives the first toast's original deadline.
    act(() => vi.advanceTimersByTime(TOAST_MS.warn - 500))
    expect(result.current.toasts[0]?.leaving).toBe(false)
    act(() => vi.advanceTimersByTime(500))
    expect(result.current.toasts[0]?.leaving).toBe(true)
  })

  it('does not collapse a different message, a different tone, or a repeat after the window', () => {
    const { result } = setup()
    act(() => {
      result.current.toast('Paused')
      result.current.toast('Resumed')
      result.current.toast('Paused', 'warn')
    })
    expect(result.current.toasts).toHaveLength(3)

    act(() => vi.advanceTimersByTime(DEDUPE_MS))
    act(() => result.current.toast('Paused', 'warn'))
    expect(result.current.toasts).toHaveLength(4)
  })

  it(`keeps at most ${MAX_TOASTS} on screen, retiring the oldest`, () => {
    const { result } = setup()
    act(() => {
      for (let i = 0; i < MAX_TOASTS + 2; i++) result.current.toast(`Toast ${i}`)
    })
    const live = result.current.toasts.filter((t) => !t.leaving).map((t) => t.message)
    expect(live).toEqual(['Toast 2', 'Toast 3', 'Toast 4', 'Toast 5'])
    act(() => vi.advanceTimersByTime(EXIT_MS))
    expect(result.current.toasts).toHaveLength(MAX_TOASTS)
  })

  it('clears pending timers on unmount', () => {
    const { result, unmount } = setup()
    act(() => result.current.toast('Paused'))
    unmount()
    expect(vi.getTimerCount()).toBe(0)
  })

  describe('actions', () => {
    it('runs the action once and reports the close as the action', () => {
      const { result } = setup()
      const run = vi.fn()
      const onClose = vi.fn()
      let id = 0
      act(() => {
        id = result.current.toast('Removed x', 'trash', { action: { label: 'Undo', run }, onClose })
      })
      act(() => result.current.act(id))
      act(() => result.current.act(id))
      expect(run).toHaveBeenCalledTimes(1)
      expect(onClose).toHaveBeenCalledTimes(1)
      expect(onClose).toHaveBeenCalledWith('action')
      expect(result.current.toasts[0]?.leaving).toBe(true)
    })

    it('honours a custom duration and reports a timeout', () => {
      const { result } = setup()
      const onClose = vi.fn()
      act(() => {
        result.current.toast('Removed x', 'trash', { ms: UNDO_MS, onClose })
      })
      act(() => vi.advanceTimersByTime(TOAST_MS.trash + 10))
      expect(onClose).not.toHaveBeenCalled()
      act(() => vi.advanceTimersByTime(UNDO_MS))
      expect(onClose).toHaveBeenCalledWith('timeout')
    })

    it('never merges two toasts that carry callbacks', () => {
      const { result } = setup()
      act(() => {
        result.current.toast('Removed', 'trash', { onClose: () => {} })
        result.current.toast('Removed', 'trash', { onClose: () => {} })
      })
      expect(result.current.toasts).toHaveLength(2)
    })

    it('reports the ✕ as a dismiss', () => {
      const { result } = setup()
      const onClose = vi.fn()
      let id = 0
      act(() => {
        id = result.current.toast('Removed', 'trash', { onClose })
      })
      act(() => result.current.dismiss(id))
      expect(onClose).toHaveBeenCalledWith('dismiss')
    })
  })
})
