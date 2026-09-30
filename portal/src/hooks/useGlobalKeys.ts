import { useEffect } from 'react'
import { resolveShortcut, type ShortcutId } from '../lib/shortcuts'
import { useStableCallback } from './useStableCallback'

interface GlobalKeys {
  /** Escape anywhere a dialog or menu has not already claimed it. */
  onEscape: () => void
  /** ⌘/Ctrl+A with nothing focused. Returns false when there is nothing to select, so the browser keeps the key. */
  onSelectAll: () => boolean
  /**
   * The single-key shortcuts (see `lib/shortcuts`). Returns false when it did nothing, so the
   * browser keeps the key (Space still scrolls, Backspace still works elsewhere).
   */
  onShortcut?: (id: ShortcutId) => boolean
  /** False while a modal is up: its own keys win, and nothing behind it may change. */
  shortcutsEnabled?: boolean
}

/** Document-level shortcuts. Handlers are read fresh on every key, so callers may pass inline functions. */
export function useGlobalKeys(handlers: GlobalKeys) {
  const onEscape = useStableCallback(handlers.onEscape)
  const onSelectAll = useStableCallback(handlers.onSelectAll)
  const onShortcut = useStableCallback((id: ShortcutId) => handlers.onShortcut?.(id) ?? false)
  const enabled = handlers.shortcutsEnabled ?? true

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        onEscape()
        return
      }
      // In a field ⌘/Ctrl+A still selects text; only an unfocused page selects the list.
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'a' && document.activeElement === document.body) {
        if (onSelectAll()) e.preventDefault()
        return
      }
      if (!enabled) return
      const id = resolveShortcut(e)
      if (id && onShortcut(id)) e.preventDefault()
    }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [onEscape, onSelectAll, onShortcut, enabled])
}
