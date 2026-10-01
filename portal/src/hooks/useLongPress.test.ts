import { act, renderHook } from '@testing-library/react'
import type { MouseEvent, PointerEvent } from 'react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { LONG_PRESS_MS, useLongPress } from './useLongPress'

beforeEach(() => vi.useFakeTimers())
afterEach(() => vi.useRealTimers())

const target = document.createElement('div')
const pointer = (over: Partial<PointerEvent<HTMLElement>> = {}) =>
  ({ pointerType: 'touch', isPrimary: true, clientX: 0, clientY: 0, target, ...over }) as PointerEvent<HTMLElement>
const click = () => {
  const e = { type: 'click', preventDefault: vi.fn(), stopPropagation: vi.fn() }
  return e as unknown as MouseEvent & typeof e
}

describe('useLongPress', () => {
  it('fires after the hold and swallows the click that follows', () => {
    const onLong = vi.fn()
    const { result } = renderHook(() => useLongPress(onLong))
    act(() => result.current.onPointerDown(pointer()))
    act(() => vi.advanceTimersByTime(LONG_PRESS_MS))
    expect(onLong).toHaveBeenCalledWith(target)
    const e = click()
    result.current.onClickCapture(e)
    expect(e.stopPropagation).toHaveBeenCalled()
    const next = click()
    result.current.onClickCapture(next)
    expect(next.stopPropagation).not.toHaveBeenCalled()
  })

  it('is cancelled by lifting early or by scrolling', () => {
    const onLong = vi.fn()
    const { result } = renderHook(() => useLongPress(onLong))
    act(() => result.current.onPointerDown(pointer()))
    act(() => result.current.onPointerUp())
    act(() => result.current.onPointerDown(pointer()))
    act(() => result.current.onPointerMove(pointer({ clientY: 30 })))
    act(() => vi.advanceTimersByTime(LONG_PRESS_MS * 2))
    expect(onLong).not.toHaveBeenCalled()
  })

  it('ignores a mouse', () => {
    const onLong = vi.fn()
    const { result } = renderHook(() => useLongPress(onLong))
    act(() => result.current.onPointerDown(pointer({ pointerType: 'mouse' })))
    act(() => vi.advanceTimersByTime(LONG_PRESS_MS * 2))
    expect(onLong).not.toHaveBeenCalled()
  })
})
