import { useEffect } from 'react'
import { useStableCallback } from './useStableCallback'

interface GlobalKeys {
  /** Escape anywhere a dialog or menu has not already claimed it. */
  onEscape: () => void
  /** ⌘/Ctrl+A with nothing focused. Returns false when there is nothing to select, so the browser keeps the key. */
  onSelectAll: () => boolean
}

/** Document-level shortcuts. Handlers are read fresh on every key, so callers may pass inline functions. */
export function useGlobalKeys(handlers: GlobalKeys) {
  const onEscape = useStableCallback(handlers.onEscape)
  const onSelectAll = useStableCallback(handlers.onSelectAll)

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        onEscape()
        return
      }
      // In a field ⌘/Ctrl+A still selects text; only an unfocused page selects the list.
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'a' && document.activeElement === document.body) {
        if (onSelectAll()) e.preventDefault()
      }
    }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [onEscape, onSelectAll])
}
