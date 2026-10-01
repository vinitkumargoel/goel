import { useRef, useState, type PointerEvent } from 'react'
import { useStableCallback } from './useStableCallback'

/** A drag past this many pixels dismisses the sheet; a shorter one springs back. */
export const DISMISS_PX = 80

/** A drag up past this many pixels grows the sheet to its tall detent. */
export const EXPAND_PX = 60

/** Movement under this is a tap on the grabber, which switches detents. */
const TAP_PX = 4

/**
 * Drag handling for a bottom sheet's grabber, with two detents: the resting height and a tall one.
 * `offset` is how far the sheet should follow the finger — negative while pulled up from the
 * resting detent, positive while pulled down. Up past `EXPAND_PX` goes tall; down past
 * `DISMISS_PX` steps back to the resting detent, or from there calls `onDismiss`. A tap toggles.
 */
export function useSheetDrag(onDismiss: () => void) {
  const [offset, setOffset] = useState(0)
  const [expanded, setExpanded] = useState(false)
  const start = useRef<number | null>(null)
  const dismiss = useStableCallback(onDismiss)

  const end = (dy: number) => {
    start.current = null
    setOffset(0)
    if (Math.abs(dy) < TAP_PX) setExpanded((e) => !e)
    else if (dy < -EXPAND_PX) setExpanded(true)
    else if (dy > DISMISS_PX) {
      if (expanded) setExpanded(false)
      else dismiss()
    }
  }

  const handlers = {
    onPointerDown: (e: PointerEvent<HTMLElement>) => {
      start.current = e.clientY
      e.currentTarget.setPointerCapture?.(e.pointerId)
    },
    onPointerMove: (e: PointerEvent<HTMLElement>) => {
      if (start.current == null) return
      const dy = e.clientY - start.current
      // Already tall: only downward follows the finger.
      setOffset(expanded ? Math.max(0, dy) : dy)
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

  return { offset, dragging: offset !== 0, expanded, setExpanded, handlers }
}
