import { useEffect } from 'react'
import { summarizeLinks } from '../lib/links'
import { useStableCallback } from './useStableCallback'

/** Where a paste belongs to the element itself: text fields and editable regions. */
function isEditable(el: EventTarget | null): boolean {
  if (!(el instanceof HTMLElement)) return false
  if (el.isContentEditable) return true
  return el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.tagName === 'SELECT'
}

/**
 * ⌘/Ctrl+V with no field focused: if the clipboard holds at least one link the server can queue,
 * the Add dialog opens with it. Anything else is left alone.
 */
export function usePasteToAdd(enabled: boolean, onLinks: (text: string) => void) {
  const handle = useStableCallback(onLinks)
  useEffect(() => {
    if (!enabled) return
    const onPaste = (e: ClipboardEvent) => {
      if (e.defaultPrevented || isEditable(e.target) || isEditable(document.activeElement)) return
      const text = e.clipboardData?.getData('text/plain')?.trim() ?? ''
      if (!text || summarizeLinks(text).valid === 0) return
      e.preventDefault()
      handle(text)
    }
    document.addEventListener('paste', onPaste)
    return () => document.removeEventListener('paste', onPaste)
  }, [enabled, handle])
}
