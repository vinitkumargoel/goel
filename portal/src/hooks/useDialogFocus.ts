import { useEffect, useState, type RefObject } from 'react'
import { useStableCallback } from './useStableCallback'

const FOCUSABLE =
  'a[href],button:not([disabled]),input:not([disabled]),select:not([disabled]),' +
  'textarea:not([disabled]),[tabindex]:not([tabindex="-1"])'

interface DialogFocusOptions {
  /** False while a stacked child dialog is open: the child then owns Tab and Escape. */
  trap?: boolean
  /** Escape anywhere on the page while this is the top dialog. */
  onEscape?: () => void
  /** Move focus into the dialog on mount (default true); off for a panel that is not modal. */
  initialFocus?: boolean
}

/**
 * Modal focus handling: remembers what had focus when the dialog mounted and hands it back on
 * unmount, moves focus in on mount (first control, else the sheet), and keeps Tab inside the dialog.
 *
 * Tab and Escape are handled at the document, in the capture phase, not on the dialog element:
 * when focus has fallen to <body> (a click on the scrim, a removed button) the dialog's own
 * handler never sees the key, and Tab would walk into the page behind. The page behind is also
 * `inert` while a modal is up (see App), so this is the second of two locks, not the only one.
 */
export function useDialogFocus(ref: RefObject<HTMLElement | null>, options: DialogFocusOptions = {}) {
  const { trap = true, initialFocus = true } = options
  // Read during the first render, before the commit that makes the page behind inert: a browser
  // may blur a focused element once it turns inert, and an effect would then see <body>.
  const [opener] = useState(() => document.activeElement)
  const onEscape = useStableCallback(() => options.onEscape?.())
  const hasEscape = options.onEscape != null

  useEffect(() => {
    const root = ref.current
    if (!initialFocus || !root || root.contains(document.activeElement)) return
    // First control, else the sheet itself so a screen reader starts at the dialog and Tab has a start.
    const first = root.querySelector<HTMLElement>(FOCUSABLE)
    if (first) first.focus()
    else {
      if (!root.hasAttribute('tabindex')) root.tabIndex = -1
      root.focus()
    }
    // Mount only.
  }, [])

  useEffect(() => {
    return () => {
      if (opener instanceof HTMLElement && opener.isConnected) opener.focus()
    }
  }, [opener])

  useEffect(() => {
    if (!trap) return
    const onKey = (e: KeyboardEvent) => {
      const root = ref.current
      if (!root) return
      if (e.key === 'Escape' && hasEscape) {
        // An inline editor inside the dialog (a tracker form) takes its own Escape first: it
        // marks itself `data-local-escape`, and the dialog closes only on the next press.
        const target = e.target instanceof Element ? e.target : null
        if (target && root.contains(target) && target.closest('[data-local-escape]')) return
        e.preventDefault()
        e.stopPropagation()
        onEscape()
        return
      }
      if (e.key !== 'Tab') return
      const items = [...root.querySelectorAll<HTMLElement>(FOCUSABLE)]
      const first = items[0]
      const last = items[items.length - 1]
      if (!first || !last) {
        e.preventDefault()
        return
      }
      const active = document.activeElement
      const inside = root.contains(active)
      if (e.shiftKey && (active === first || !inside)) {
        e.preventDefault()
        last.focus()
      } else if (!e.shiftKey && (active === last || !inside)) {
        e.preventDefault()
        first.focus()
      }
    }
    document.addEventListener('keydown', onKey, true)
    return () => document.removeEventListener('keydown', onKey, true)
  }, [ref, trap, hasEscape, onEscape])
}
