import { useCallback, useEffect, useRef, type KeyboardEvent, type RefObject } from 'react'

const FOCUSABLE =
  'a[href],button:not([disabled]),input:not([disabled]),select:not([disabled]),' +
  'textarea:not([disabled]),[tabindex]:not([tabindex="-1"])'

/**
 * Modal focus handling: remembers what had focus when the dialog mounted and hands it back on
 * unmount, and keeps Tab inside the dialog. `trap: false` lets a stacked child dialog own Tab.
 */
export function useDialogFocus(ref: RefObject<HTMLElement | null>, trap = true) {
  const opener = useRef<Element | null>(null)

  useEffect(() => {
    opener.current = document.activeElement
    return () => {
      const el = opener.current
      if (el instanceof HTMLElement && el.isConnected) el.focus()
    }
  }, [])

  return useCallback(
    (e: KeyboardEvent) => {
      if (!trap || e.key !== 'Tab' || !ref.current) return
      const items = [...ref.current.querySelectorAll<HTMLElement>(FOCUSABLE)]
      const first = items[0]
      const last = items[items.length - 1]
      if (!first || !last) return
      const active = document.activeElement
      if (e.shiftKey && (active === first || !ref.current.contains(active))) {
        e.preventDefault()
        last.focus()
      } else if (!e.shiftKey && (active === last || !ref.current.contains(active))) {
        e.preventDefault()
        first.focus()
      }
    },
    [ref, trap],
  )
}
