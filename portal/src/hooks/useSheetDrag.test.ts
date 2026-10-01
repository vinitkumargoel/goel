import { act, renderHook } from '@testing-library/react'
import type { PointerEvent } from 'react'
import { describe, expect, it, vi } from 'vitest'
import { useSheetDrag } from './useSheetDrag'

const at = (clientY: number) =>
  ({ clientY, pointerId: 1, currentTarget: { setPointerCapture: () => {} } }) as unknown as PointerEvent<HTMLElement>

function drag(result: { current: ReturnType<typeof useSheetDrag> }, from: number, to: number) {
  act(() => result.current.handlers.onPointerDown(at(from)))
  act(() => result.current.handlers.onPointerMove(at(to)))
  act(() => result.current.handlers.onPointerUp(at(to)))
}

describe('useSheetDrag', () => {
  it('grows to the tall detent on a drag up, and follows the finger meanwhile', () => {
    const onDismiss = vi.fn()
    const { result } = renderHook(() => useSheetDrag(onDismiss))
    act(() => result.current.handlers.onPointerDown(at(300)))
    act(() => result.current.handlers.onPointerMove(at(250)))
    expect(result.current.offset).toBe(-50)
    act(() => result.current.handlers.onPointerUp(at(200)))
    expect(result.current.expanded).toBe(true)
    expect(result.current.offset).toBe(0)
  })

  it('steps down from tall to resting before it dismisses', () => {
    const onDismiss = vi.fn()
    const { result } = renderHook(() => useSheetDrag(onDismiss))
    drag(result, 300, 200)
    drag(result, 100, 300)
    expect(result.current.expanded).toBe(false)
    expect(onDismiss).not.toHaveBeenCalled()
    drag(result, 100, 300)
    expect(onDismiss).toHaveBeenCalledTimes(1)
  })

  it('toggles on a tap', () => {
    const { result } = renderHook(() => useSheetDrag(() => {}))
    drag(result, 100, 101)
    expect(result.current.expanded).toBe(true)
    drag(result, 100, 100)
    expect(result.current.expanded).toBe(false)
  })
})
