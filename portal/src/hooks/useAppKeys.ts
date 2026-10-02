import { eligibleFor } from '../lib/bulk'
import type { RouteView as View } from '../lib/route'
import type { Filter } from '../lib/filters'
import type { SelectionAction } from '../lib/selection'
import { filterForShortcut, type ShortcutId } from '../lib/shortcuts'
import type { RowAction } from '../lib/taskKind'
import type { TaskRow } from '../lib/types'
import { useGlobalKeys } from './useGlobalKeys'
import { useStableCallback } from './useStableCallback'

export interface AppKeyDeps {
  /** False while a modal is up. Escape still reaches `onEscape`. */
  enabled: boolean
  onEscape: () => void
  view: View
  /** The library rows on screen, in order. */
  visible: readonly TaskRow[]
  lead: string | null
  selectedVisible: readonly TaskRow[]
  canWrite: boolean
  select: (action: SelectionAction) => void
  openDetail: (id: string) => void
  runBulk: (action: RowAction, ids: string[]) => Promise<void>
  /** Goes through the confirm dialog. */
  removeMany: (ids: string[]) => void
  openAdd: () => void
  focusSearch: () => void
  openHelp: () => void
  /** The row element for an id, to focus and reveal. */
  rowElement: (id: string) => HTMLElement | undefined
  /** 1–9: a sidebar filter, showing the library. */
  goToFilter?: (filter: Filter) => void
  /** G H, G S. */
  goToView?: (view: View) => void
  /** C: the selection's links, one per line. */
  copy?: (text: string) => void
  /** ⌘/Ctrl+K. */
  openPalette?: () => void
}

/**
 * What each single-key shortcut does. Returns false when it did nothing (nothing selected, a
 * read-only session, another view), so the key keeps its default behaviour.
 */
export function runShortcut(id: ShortcutId, deps: AppKeyDeps): boolean {
  switch (id) {
    case 'help':
      deps.openHelp()
      return true
    case 'search':
      deps.focusSearch()
      return true
    case 'add':
      if (!deps.canWrite) return false
      deps.openAdd()
      return true
    case 'go-history':
    case 'go-settings':
      if (!deps.goToView) return false
      deps.goToView(id === 'go-history' ? 'history' : 'settings')
      return true
  }
  const filter = filterForShortcut(id)
  if (filter) {
    if (!deps.goToFilter) return false
    deps.goToFilter(filter)
    return true
  }
  if (deps.view !== 'library') return false
  const { visible, lead, selectedVisible } = deps

  switch (id) {
    case 'next':
    case 'prev': {
      if (visible.length === 0) return false
      const at = lead == null ? -1 : visible.findIndex((t) => t.id === lead)
      const step = id === 'next' ? 1 : -1
      const index =
        at < 0 ? (step > 0 ? 0 : visible.length - 1) : Math.max(0, Math.min(visible.length - 1, at + step))
      const target = visible[index]!
      deps.select({ type: 'single', id: target.id })
      const el = deps.rowElement(target.id)
      el?.focus()
      el?.scrollIntoView?.({ block: 'nearest' })
      return true
    }
    case 'open':
      if (lead == null || !selectedVisible.some((t) => t.id === lead)) return false
      deps.openDetail(lead)
      return true
    case 'toggle': {
      if (!deps.canWrite || selectedVisible.length === 0) return false
      // Anything running pauses; only a selection with nothing running resumes.
      const pausable = eligibleFor(selectedVisible, 'pause')
      if (pausable.length > 0) {
        void deps.runBulk('pause', pausable)
        return true
      }
      const resumable = eligibleFor(selectedVisible, 'resume')
      if (resumable.length === 0) return false
      void deps.runBulk('resume', resumable)
      return true
    }
    case 'remove':
      if (!deps.canWrite || selectedVisible.length === 0) return false
      deps.removeMany(selectedVisible.map((t) => t.id))
      return true
    case 'retry': {
      const failed = deps.canWrite ? eligibleFor(selectedVisible, 'retry') : []
      if (failed.length === 0) return false
      void deps.runBulk('retry', failed)
      return true
    }
    case 'copy':
      if (!deps.copy || selectedVisible.length === 0) return false
      deps.copy(selectedVisible.map((t) => t.source).join('\n'))
      return true
  }
  return false
}

/** The app's document-level keys: Escape, ⌘/Ctrl+A, and the single-key shortcuts. */
export function useAppKeys(deps: AppKeyDeps) {
  const onShortcut = useStableCallback((id: ShortcutId) => runShortcut(id, deps))
  useGlobalKeys({
    onEscape: deps.onEscape,
    onSelectAll: () => {
      if (deps.view !== 'library' || deps.visible.length === 0) return false
      deps.select({ type: 'all', order: deps.visible.map((task) => task.id) })
      return true
    },
    onShortcut,
    shortcutsEnabled: deps.enabled,
    onPalette: deps.openPalette,
  })
}
