import { useRef, useState, type PointerEvent } from 'react'
import { useStableCallback } from './useStableCallback'

/** A drag past this many pixels dismisses the sheet; a shorter one springs back. */
export const DISMISS_PX = 80

/**
 * Drag-down-to-dismiss for a bottom sheet's grabber. `offset` is how far the sheet should follow
 * the finger (never upward); releasing past `DISMISS_PX` calls `onDismiss`.
 */
export function useSheetDrag(onDismiss: () => void) {
  const [offset, setOffset] = useState(0)
  const start = useRef<number | null>(null)
  const dismiss = useStableCallback(onDismiss)

  const end = (dy: number) => {
    start.current = null
    setOffset(0)
    if (dy > DISMISS_PX) dismiss()
  }

  const handlers = {
    onPointerDown: (e: PointerEvent<HTMLElement>) => {
      start.current = e.clientY
      e.currentTarget.setPointerCapture?.(e.pointerId)
    },
    onPointerMove: (e: PointerEvent<HTMLElement>) => {
      if (start.current == null) return
      setOffset(Math.max(0, e.clientY - start.current))
    },
    onPointerUp: (e: PointerEvent<HTMLElement>) => {
      if (start.current == null) return
      end(e.clientY - start.current)
    },
    onPointerCancel: () => {
      start.current = null
      setOffset(0)
    },
  }

  return { offset, dragging: offset > 0, handlers }
}
