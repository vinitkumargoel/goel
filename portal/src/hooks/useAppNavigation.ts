import { useCallback, useEffect, type RefObject } from 'react'
import { useTranslation } from 'react-i18next'
import type { View } from '../components/shell/Rail'
import type { Filter as LibraryFilter } from '../lib/filters'
import { formatRoute, parseRoute } from '../lib/route'
import { nextSort, type SortKey } from '../lib/sort'
import type { TaskRow } from '../lib/types'
import type { AppState } from './useAppState'
import { useStableCallback } from './useStableCallback'

/** The card or row for a task id: the detail sheet hands focus back to it when it closes. */
export function rowElement(id: string): HTMLElement | undefined {
  return [...document.querySelectorAll<HTMLElement>('[role="option"][data-id]')].find(
    (el) => el.dataset.id === id,
  )
}

interface Deps {
  state: AppState
  visible: readonly TaskRow[]
  detailId: string | null
  panelShown: boolean
  settingsDirtyRef: RefObject<boolean>
  revealRows: (ids: readonly string[]) => void
}

/**
 * Moving around the window: views (guarded by unsaved settings), sidebar filters and tags, the
 * detail panel, and jumping to a task wherever the current filter left it.
 */
export function useAppNavigation({ state, visible, detailId, panelShown, settingsDirtyRef, revealRows }: Deps) {
  const { t } = useTranslation()
  const { setView, setSidebarOpen, setConfirmReq, setFilter, setTag, setSearch, select, setSort } = state
  const { panelOpen, setPanelOpen, panelAutoHide, setPanelAutoHide } = state

  const selectView = useCallback(
    (next: View) => {
      const go = () => {
        setView(next)
        setSidebarOpen(false)
      }
      if (next === 'settings' || !settingsDirtyRef.current) return go()
      setConfirmReq({
        title: t('settings.leave.title'),
        body: t('settings.leave.body'),
        confirmLabel: t('settings.leave.confirm'),
        onConfirm: go,
      })
    },
    [t, setView, setSidebarOpen, setConfirmReq, settingsDirtyRef],
  )

  // Stable, like every handler handed to LibraryView: a fresh identity would re-render each memoised row.
  const openDetail = useStableCallback((id: string) => {
    select({ type: 'single', id })
    if (!panelOpen) setPanelOpen(true)
  })

  /** The status bar's and the overview's figures jump to that sidebar filter. */
  const goToFilter = useCallback(
    (f: LibraryFilter) => {
      setFilter(f)
      setTag(null)
      selectView('library')
    },
    [selectView, setFilter, setTag],
  )

  const goToTag = useCallback(
    (next: string) => {
      setFilter('all')
      setTag(next)
      selectView('library')
    },
    [selectView, setFilter, setTag],
  )

  /** Just added (or "Show" on the added toast): unfiltered, those rows selected, scrolled to, pulsed. */
  const revealAdded = useStableCallback((ids: string[]) => {
    goToFilter('all')
    setSearch('')
    select({ type: 'set', ids })
    revealRows(ids)
  })

  /** The palette's download results: shown even when the current filter or search hides them. */
  const showTask = useStableCallback((id: string) => {
    if (!visible.some((task) => task.id === id)) {
      goToFilter('all')
      setSearch('')
    } else selectView('library')
    openDetail(id)
    revealRows([id])
  })

  const onSort = useCallback((key: SortKey) => setSort((s) => nextSort(s, key)), [setSort])

  // With auto-hide hiding it, the toggle means "show me the overview": that takes auto-hide off.
  const togglePanel = useCallback(() => {
    if (!panelShown && panelOpen && panelAutoHide) return setPanelAutoHide(false)
    setPanelOpen((p) => !p)
  }, [panelShown, panelOpen, panelAutoHide, setPanelAutoHide, setPanelOpen])

  const clearSearch = useCallback(() => {
    setSearch('')
    setFilter('all')
  }, [setSearch, setFilter])

  /** Closing from inside the panel would strand focus in an inert region: hand it back to the row. */
  const closePanel = useCallback(() => {
    setPanelOpen(false)
    if (detailId != null) rowElement(detailId)?.focus()
  }, [detailId, setPanelOpen])

  return {
    selectView,
    openDetail,
    goToFilter,
    goToTag,
    revealAdded,
    showTask,
    onSort,
    togglePanel,
    clearSearch,
    closePanel,
  }
}

/**
 * Keeps the address bar and the window in step. Mirrored with replaceState: switching views is
 * not a step Back should retrace. A hand-edited address (or a pasted link) re-routes without a reload.
 */
export function useRouteSync(state: AppState, selectedLead: string | null) {
  const { view, filter, setView, setFilter, select, setPanelOpen } = state

  useEffect(() => {
    const hash = formatRoute({ view, filter, task: view === 'library' ? selectedLead : null })
    if (location.hash !== hash) history.replaceState(history.state, '', hash)
  }, [view, filter, selectedLead])

  useEffect(() => {
    const onHash = () => {
      const r = parseRoute(location.hash)
      setView(r.view)
      setFilter(r.filter)
      if (r.task) {
        select({ type: 'single', id: r.task })
        setPanelOpen(true)
      }
    }
    window.addEventListener('hashchange', onHash)
    return () => window.removeEventListener('hashchange', onHash)
  }, [setView, setFilter, select, setPanelOpen])
}
