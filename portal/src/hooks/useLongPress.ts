import { useEffect, useRef, type MouseEvent, type PointerEvent } from 'react'
import { useStableCallback } from './useStableCallback'

/** How long a finger has to rest before it counts as a long press. */
export const LONG_PRESS_MS = 400

/** A finger that wanders further than this is scrolling, not pressing. */
const SLOP_PX = 10

/**
 * Touch long-press for a container. Spread the handlers on it; `onLongPress` gets the element the
 * press started on. The click (and the context menu) that the same touch produces afterwards is
 * swallowed, so a long press never also opens what it was held on.
 */
export function useLongPress(onLongPress: (target: HTMLElement) => void) {
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null)
  const origin = useRef<{ x: number; y: number } | null>(null)
  const fired = useRef(false)
  const run = useStableCallback(onLongPress)

  const cancel = () => {
    if (timer.current) clearTimeout(timer.current)
    timer.current = null
    origin.current = null
  }

  useEffect(() => cancel, [])

  const swallow = (e: MouseEvent) => {
    if (!fired.current) return
    e.preventDefault()
    e.stopPropagation()
    if (e.type === 'click') fired.current = false
  }

  return {
    onPointerDown: (e: PointerEvent<HTMLElement>) => {
      fired.current = false
      if (e.pointerType !== 'touch' || !e.isPrimary) return
      const target = e.target as HTMLElement
      origin.current = { x: e.clientX, y: e.clientY }
      timer.current = setTimeout(() => {
        timer.current = null
        fired.current = true
        navigator.vibrate?.(10)
        run(target)
      }, LONG_PRESS_MS)
    },
    onPointerMove: (e: PointerEvent<HTMLElement>) => {
      const o = origin.current
      if (o && Math.hypot(e.clientX - o.x, e.clientY - o.y) > SLOP_PX) cancel()
    },
    onPointerUp: cancel,
    onPointerCancel: cancel,
    onClickCapture: swallow,
    onContextMenuCapture: (e: MouseEvent) => {
      // A touch-and-hold is this hook's; the browser's own long-press menu must not open too.
      if (timer.current || fired.current) {
        e.preventDefault()
        e.stopPropagation()
      }
    },
  }
}
