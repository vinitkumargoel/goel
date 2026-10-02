import { useCallback, useEffect, useReducer, useRef, useState } from 'react'
import type { ConfirmRequest } from '../components/dialogs/ConfirmDialog'
import type { DetailTab } from '../components/detail/DetailPanes'
import type { Filter, View } from '../components/shell/Rail'
import type { MenuState } from '../components/ui/Menu'
import { NARROW_MAX } from '../lib/breakpoints'
import { loadPanelAutoHide, loadRailExpanded, savePanelAutoHide, saveRailExpanded } from '../lib/prefs'
import { loadSort, parseRoute, saveSort } from '../lib/route'
import { EMPTY_SELECTION, selectionReducer } from '../lib/selection'
import type { SortState } from '../lib/sort'

/** Wider than this, the detail sheet sits beside the board and starts open. */
export const PANEL_BREAKPOINT = NARROW_MAX

/** The app's one context menu, tagged with what opened it so that control can show it is open. */
export type AppMenu = MenuState & { owner: 'row' | 'user' | 'bandwidth' }

/**
 * The window's own state: where the user is (view, filter, search, sort, tag, selection), which
 * layers are open, and the panel and rail layout prefs. Derived values live in useLibraryModel.
 */
export function useAppState() {
  // The address bar is the source of truth at load: a bookmark or a reload lands where it left.
  const [initial] = useState(() => parseRoute(location.hash))
  const [view, setView] = useState<View>(initial.view)
  const [filter, setFilter] = useState<Filter>(initial.filter)
  const [search, setSearch] = useState('')
  const [sort, setSort] = useState<SortState>(loadSort)
  const [selection, select] = useReducer(selectionReducer, EMPTY_SELECTION, (empty) =>
    initial.task ? selectionReducer(empty, { type: 'single', id: initial.task }) : empty,
  )
  const [tab, setTab] = useState<DetailTab>('overview')
  const panel = usePanelLayout(initial.task != null)
  const [menu, setMenu] = useState<AppMenu | null>(null)
  const [confirmReq, setConfirmReq] = useState<ConfirmRequest | null>(null)
  const [helpOpen, setHelpOpen] = useState(false)
  // A sidebar tag narrows the list on its own; picking any status or type filter clears it.
  const [tag, setTag] = useState<string | null>(null)
  const [playing, setPlaying] = useState<string | null>(null)

  useEffect(() => saveSort(sort), [sort])

  return {
    view,
    setView,
    filter,
    setFilter,
    search,
    setSearch,
    sort,
    setSort,
    selection,
    select,
    tab,
    setTab,
    menu,
    setMenu,
    confirmReq,
    setConfirmReq,
    helpOpen,
    setHelpOpen,
    tag,
    setTag,
    playing,
    setPlaying,
    ...panel,
  }
}

export type AppState = ReturnType<typeof useAppState>

/** The detail panel (open, auto-hide), the phone's filter drawer and the rail's pinned width. */
function usePanelLayout(openForTask: boolean) {
  const [panelOpen, setPanelOpen] = useState(() => window.innerWidth > PANEL_BREAKPOINT || openForTask)
  const [panelAutoHide, setPanelAutoHideState] = useState(loadPanelAutoHide)
  const setPanelAutoHide = useCallback((on: boolean) => {
    setPanelAutoHideState(on)
    savePanelAutoHide(on)
  }, [])
  /** The phone's filter drawer. */
  const [sidebarOpen, setSidebarOpen] = useState(false)
  const [railExpanded, setRailExpanded] = useState(loadRailExpanded)
  const toggleRail = useCallback(() => {
    setRailExpanded((on) => {
      saveRailExpanded(!on)
      return !on
    })
  }, [])

  // Crossing the breakpoint resets the panel to that layout's default; a toggle within one layout sticks.
  useEffect(() => {
    if (typeof window.matchMedia !== 'function') return
    const wide = window.matchMedia(`(min-width: ${PANEL_BREAKPOINT + 1}px)`)
    const onChange = (e: MediaQueryListEvent) => setPanelOpen(e.matches)
    wide.addEventListener('change', onChange)
    return () => wide.removeEventListener('change', onChange)
  }, [])

  return {
    panelOpen,
    setPanelOpen,
    panelAutoHide,
    setPanelAutoHide,
    sidebarOpen,
    setSidebarOpen,
    railExpanded,
    toggleRail,
  }
}

/**
 * Settings reports unsaved server edits; leaving would drop them. The ref lets callbacks read the
 * latest value without re-creating, and the page asks before an unload while it is set.
 */
export function useSettingsDirty() {
  const [settingsDirty, setSettingsDirty] = useState(false)
  const settingsDirtyRef = useRef(false)
  settingsDirtyRef.current = settingsDirty

  useEffect(() => {
    if (!settingsDirty) return
    const warn = (e: BeforeUnloadEvent) => e.preventDefault()
    window.addEventListener('beforeunload', warn)
    return () => window.removeEventListener('beforeunload', warn)
  }, [settingsDirty])

  return { setSettingsDirty, settingsDirtyRef }
}
