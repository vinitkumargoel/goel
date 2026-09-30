import { useCallback, useEffect, useMemo, useReducer, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { BulkBar } from './components/BulkBar'
import { ConfirmDialog, type ConfirmRequest } from './components/ConfirmDialog'
import { ContextMenu, type MenuState } from './components/ContextMenu'
import { DetailPanel } from './components/DetailPanel'
import type { DetailTab } from './components/DetailPanes'
import { HistoryView } from './components/HistoryView'
import { LibraryView } from './components/LibraryView'
import { QueueOverview } from './components/QueueOverview'
import { isStale, ReconnectBanner } from './components/ReconnectBanner'
import { SettingsView } from './components/SettingsView'
import { ShortcutsDialog } from './components/ShortcutsDialog'
import { Sidebar, type Filter, type View } from './components/Sidebar'
import { StatusBar } from './components/StatusBar'
import { Toasts } from './components/Toasts'
import { Topbar } from './components/Topbar'
import { useAddFlow } from './hooks/useAddFlow'
import { useBandwidth } from './hooks/useBandwidth'
import { useBandwidthMenu } from './hooks/useBandwidthMenu'
import { useDetail } from './hooks/useDetail'
import { useMenus } from './hooks/useMenus'
import { useNow } from './hooks/useNow'
import { useSearchFocus } from './hooks/useSearchFocus'
import { useAppKeys } from './hooks/useAppKeys'
import { useBackToClose } from './hooks/useBackToClose'
import { useMediaQuery } from './hooks/useMediaQuery'
import { useStableCallback } from './hooks/useStableCallback'
import { useTaskActions } from './hooks/useTaskActions'
import { useTasks } from './hooks/useTasks'
import { useThemeChoice } from './hooks/useThemeChoice'
import { useToasts } from './hooks/useToasts'
import { setRefusalHandler } from './lib/api'
import { BOOT } from './lib/boot'
import { copyText } from './lib/clipboard'
import { countFilters, filterTasks, type Filter as LibraryFilter } from './lib/filters'
import { loadPanelAutoHide, panelVisible, savePanelAutoHide } from './lib/prefs'
import { formatRoute, loadSort, parseRoute, saveSort } from './lib/route'
import { EMPTY_SELECTION, selectionReducer } from './lib/selection'
import { nextSort, sortTasks, type SortKey, type SortState } from './lib/sort'
import type { RowAction } from './lib/taskKind'

const PANEL_BREAKPOINT = 920

type AppMenu = MenuState & { owner: 'row' | 'user' | 'bandwidth' }

/** The row element for a task id: the detail panel hands focus back to it when it closes. */
function rowElement(id: string): HTMLElement | undefined {
  return [...document.querySelectorAll<HTMLElement>('[role="option"][data-id]')].find(
    (el) => el.dataset.id === id,
  )
}

export function App() {
  const { t } = useTranslation()
  // The address bar is the source of truth at load: a bookmark or a reload lands where it left.
  const [initial] = useState(() => parseRoute(location.hash))
  const [view, setView] = useState<View>(initial.view)
  const [filter, setFilter] = useState<Filter>(initial.filter)
  const [search, setSearch] = useState('')
  const [sort, setSort] = useState<SortState>(loadSort)
  const [selection, select] = useReducer(selectionReducer, EMPTY_SELECTION, (empty) =>
    initial.task ? selectionReducer(empty, { type: 'single', id: initial.task }) : empty,
  )
  const [tab, setTab] = useState<DetailTab>('general')
  const [panelOpen, setPanelOpen] = useState(
    () => window.innerWidth > PANEL_BREAKPOINT || initial.task != null,
  )
  const [panelAutoHide, setPanelAutoHideState] = useState(loadPanelAutoHide)
  const setPanelAutoHide = useCallback((on: boolean) => {
    setPanelAutoHideState(on)
    savePanelAutoHide(on)
  }, [])
  const [sidebarOpen, setSidebarOpen] = useState(false)
  const [menu, setMenu] = useState<AppMenu | null>(null)
  const [confirmReq, setConfirmReq] = useState<ConfirmRequest | null>(null)
  const [helpOpen, setHelpOpen] = useState(false)
  const [theme, setTheme] = useThemeChoice()
  const hamburgerRef = useRef<HTMLButtonElement>(null)
  const { searchRef, mobileSearch, setMobileSearch, focusSearch } = useSearchFocus()

  const { tasks, live, loaded, error, lastUpdate, refresh, reconnect } = useTasks()
  const { toasts, toast, dismiss, pause, resume } = useToasts()
  const warn = useCallback((message: string) => toast(message, 'warn'), [toast])
  const bandwidth = useBandwidth()

  const canWrite = !BOOT.readOnly

  // Ticks only while the stream is down, for the banner's "0:14 ago".
  const now = useNow(1000, !live)
  const stale = isStale(live, lastUpdate, now)

  const tasksRef = useRef(tasks)
  tasksRef.current = tasks
  const currentIds = useCallback(() => new Set(tasksRef.current.map((task) => task.id)), [])

  const { runAction, runBulk, removeTask, removeMany, pauseAll, resumeAll } = useTaskActions({
    refresh,
    toast,
    confirm: setConfirmReq,
    currentIds,
  })

  useEffect(() => {
    setRefusalHandler(warn)
  }, [warn])

  // Crossing the breakpoint resets the panel to that layout's default; a toggle within one layout sticks.
  useEffect(() => {
    if (typeof window.matchMedia !== 'function') return
    const wide = window.matchMedia(`(min-width: ${PANEL_BREAKPOINT + 1}px)`)
    const onChange = (e: MediaQueryListEvent) => setPanelOpen(e.matches)
    wide.addEventListener('change', onChange)
    return () => wide.removeEventListener('change', onChange)
  }, [])

  useEffect(() => saveSort(sort), [sort])

  const counts = useMemo(() => countFilters(tasks), [tasks])

  const visible = useMemo(
    () => sortTasks(filterTasks(tasks, filter, search), sort),
    [tasks, filter, search, sort],
  )

  // Bulk actions apply to what the user can see: a row hidden by a filter is never acted on unseen.
  const selectedVisible = useMemo(
    () => visible.filter((task) => selection.ids.has(task.id)),
    [visible, selection.ids],
  )

  // The detail panel follows the lead row, only while it is still selected and not filtered out.
  const lead = selection.lead
  const detailId =
    lead != null && selection.ids.has(lead) && visible.some((task) => task.id === lead) ? lead : null

  // Auto-hide only takes the panel away while nothing is selected; the toggle still closes it.
  const panelShown = panelVisible(panelOpen, panelAutoHide, detailId != null)

  const { detail, setFilePriority, cyclePriority } = useDetail(
    detailId,
    tasks,
    view === 'library' && panelShown,
    warn,
  )

  // A snapshot without a selected row means it was removed elsewhere; drop it from the selection.
  useEffect(() => {
    if (loaded) select({ type: 'prune', existing: tasks.map((t) => t.id) })
  }, [tasks, loaded])

  const totals = useMemo(
    () =>
      tasks.reduce(
        (acc, t) => ({ down: acc.down + (t.downSpeed || 0), up: acc.up + (t.upSpeed || 0) }),
        { down: 0, up: 0 },
      ),
    [tasks],
  )

  const copy = useCallback(
    (text: string) => {
      void copyText(text).then((ok) =>
        ok ? toast(t('toast.copied'), 'copy') : toast(t('toast.copyFailed'), 'warn'),
      )
    },
    [toast, t],
  )

  const openMenu = useCallback((m: MenuState) => setMenu({ ...m, owner: 'row' }), [])

  const { openRowMenu, removeEntries, userMenu } = useMenus({
    tasks,
    selectedIds: selection.ids,
    selectedVisible,
    canWrite,
    select,
    openMenu,
    copy,
    toast,
    runAction,
    runBulk,
    removeTask,
    removeMany,
  })

  const openUserMenu = useCallback(
    (anchor: DOMRect) =>
      setMenu({
        ...userMenu(
          anchor,
          () => setView('settings'),
          () => setHelpOpen(true),
        ),
        owner: 'user',
      }),
    [userMenu],
  )

  const openBandwidthMenu = useBandwidthMenu(
    bandwidth,
    useCallback((m: MenuState) => setMenu({ ...m, owner: 'bandwidth' }), []),
    toast,
  )

  // Settings reports unsaved server edits; leaving would drop them, so ask first.
  const [settingsDirty, setSettingsDirty] = useState(false)
  const settingsDirtyRef = useRef(false)
  settingsDirtyRef.current = settingsDirty
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
    [t],
  )

  useEffect(() => {
    if (!settingsDirty) return
    const warn = (e: BeforeUnloadEvent) => e.preventDefault()
    window.addEventListener('beforeunload', warn)
    return () => window.removeEventListener('beforeunload', warn)
  }, [settingsDirty])

  // Stable, like every handler handed to LibraryView: a fresh identity would re-render each memoised row.
  const openDetail = useStableCallback((id: string) => {
    select({ type: 'single', id })
    if (!panelOpen) setPanelOpen(true)
  })

  const { addOpen, openAdd, closeAdd, readd, dialog } = useAddFlow({
    canWrite,
    toast,
    refresh,
    onQueued: useCallback(
      (resetFilter: boolean) => {
        if (resetFilter) setFilter('all')
        selectView('library')
      },
      [selectView],
    ),
  })

  // While a dialog is up, everything behind it is inert: Tab, a screen reader's virtual cursor and
  // a stray click can't reach it, even when focus has fallen back to <body>.
  const modalOpen = addOpen || confirmReq != null || helpOpen

  useAppKeys({
    // An open menu owns the keyboard like a modal does: N or Delete must not act behind it.
    enabled: !modalOpen && menu == null,
    onEscape: () => {
      setMenu(null)
      closeAdd()
      setSidebarOpen(false)
      setHelpOpen(false)
    },
    view,
    visible,
    lead: selection.lead,
    selectedVisible,
    canWrite,
    select,
    openDetail,
    runBulk,
    removeMany,
    openAdd,
    focusSearch: () => {
      if (view === 'settings' && settingsDirtyRef.current) return selectView('library')
      setView('library')
      focusSearch()
    },
    openHelp: () => setHelpOpen(true),
    rowElement,
  })

  const onRowAction = useCallback((id: string, a: RowAction) => void runAction(id, a), [runAction])

  const onSort = useCallback((key: SortKey) => setSort((s) => nextSort(s, key)), [])

  /** The status bar's and the overview's figures jump to that sidebar filter. */
  const goToFilter = useCallback(
    (f: LibraryFilter) => {
      setFilter(f)
      selectView('library')
    },
    [selectView],
  )

  // With auto-hide hiding it, the toggle means "show me the overview": that takes auto-hide off.
  const togglePanel = useCallback(() => {
    if (!panelShown && panelOpen && panelAutoHide) return setPanelAutoHide(false)
    setPanelOpen((p) => !p)
  }, [panelShown, panelOpen, panelAutoHide, setPanelAutoHide])

  const clearSearch = useCallback(() => {
    setSearch('')
    setFilter('all')
  }, [])

  /** Closing from inside the panel would strand focus in an inert region: hand it back to the row. */
  const closePanel = useCallback(() => {
    setPanelOpen(false)
    if (detailId != null) rowElement(detailId)?.focus()
  }, [detailId])

  // Mirrored with replaceState: switching views is not a step Back should retrace.
  const selectedLead = lead != null && selection.ids.has(lead) ? lead : null
  useEffect(() => {
    const hash = formatRoute({ view, filter, task: view === 'library' ? selectedLead : null })
    if (location.hash !== hash) history.replaceState(history.state, '', hash)
  }, [view, filter, selectedLead])

  // A hand-edited address (or a pasted link) re-routes without a reload.
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
  }, [])

  // Back closes whatever layer is on top rather than leaving the portal.
  const narrow = useMediaQuery(`(max-width: ${PANEL_BREAKPOINT}px)`)
  useBackToClose(view === 'library' && panelShown && narrow, closePanel)
  useBackToClose(sidebarOpen, () => setSidebarOpen(false))
  useBackToClose(addOpen, closeAdd)
  useBackToClose(helpOpen, () => setHelpOpen(false))
  useBackToClose(confirmReq != null, () => setConfirmReq(null))

  return (
    <>
      <div className={`app-chrome${stale ? ' stale' : ''}`} inert={modalOpen}>
        <Topbar
          search={search}
          onSearch={setSearch}
          searchRef={searchRef}
          mobileSearchOpen={mobileSearch}
          onMobileSearch={setMobileSearch}
          downSpeed={totals.down}
          upSpeed={totals.up}
          showSearch={view === 'library'}
          showPanelToggle={view === 'library'}
          panelOpen={panelShown}
          onTogglePanel={togglePanel}
          onAdd={openAdd}
          onToggleSidebar={() => setSidebarOpen((s) => !s)}
          onUserMenu={openUserMenu}
          userMenuOpen={menu?.owner === 'user'}
          sidebarOpen={sidebarOpen}
          hamburgerRef={hamburgerRef}
          canWrite={canWrite}
        />

        <ReconnectBanner stale={stale} lastUpdate={lastUpdate} now={now} onRetry={reconnect} />

        <div className="shell">
          <Sidebar
            view={view}
            filter={filter}
            counts={counts}
            open={sidebarOpen}
            onSelectFilter={goToFilter}
            onSelectView={selectView}
            onClose={() => setSidebarOpen(false)}
            returnFocusTo={hamburgerRef}
          />

          <main className="content">
            {view === 'library' && (
              <LibraryView
                tasks={visible}
                total={tasks.length}
                loaded={loaded}
                error={error}
                search={search}
                filtered={filter !== 'all'}
                selectedIds={selection.ids}
                lead={selection.lead}
                sort={sort}
                canWrite={canWrite}
                readOnly={BOOT.readOnly}
                onSelection={select}
                onOpen={openDetail}
                onSort={onSort}
                onAction={onRowAction}
                onMenu={openRowMenu}
                onClearSearch={clearSearch}
                onAdd={openAdd}
                onRetry={refresh}
                bulk={
                  selectedVisible.length >= 2 ? (
                    <BulkBar
                      selected={selectedVisible}
                      canWrite={canWrite}
                      onAction={(action, ids) => void runBulk(action, ids)}
                      onCopyLinks={(sources) => copy(sources.join('\n'))}
                      onRemove={removeMany}
                      onClear={() => select({ type: 'clear' })}
                    />
                  ) : undefined
                }
              />
            )}
            {view === 'history' && (
              <HistoryView
                canWrite={canWrite}
                onReadd={readd}
                onRemoved={() => toast(t('toast.entryRemoved'), 'trash')}
                onWarn={warn}
                onToast={toast}
              />
            )}
            {view === 'settings' && (
              <SettingsView
                theme={theme}
                onTheme={setTheme}
                canWrite={canWrite}
                onToast={toast}
                bandwidth={bandwidth}
                onDirtyChange={setSettingsDirty}
                panelAutoHide={panelAutoHide}
                onPanelAutoHide={setPanelAutoHide}
              />
            )}
          </main>

          {view === 'library' && (
            <DetailPanel
              detail={detail}
              open={panelShown}
              tab={tab}
              canWrite={canWrite}
              onTab={setTab}
              onClose={closePanel}
              onAction={onRowAction}
              onRemove={(id, at) => openMenu({ x: at.x, y: at.y, above: true, entries: removeEntries(id) })}
              onMore={(id, at) => openRowMenu(id, at.x, at.y, true)}
              onCopy={copy}
              onToggleFile={(fileId, wasSkipped) =>
                void setFilePriority(fileId, wasSkipped ? 'normal' : 'skip')
              }
              onCyclePriority={cyclePriority}
              trapFocus={!modalOpen}
              overview={
                detailId == null ? (
                  <QueueOverview
                    tasks={tasks}
                    counts={counts}
                    down={totals.down}
                    up={totals.up}
                    bandwidth={bandwidth.status === 'unsupported' ? null : bandwidth.state}
                    autoHide={panelAutoHide}
                    onAutoHide={setPanelAutoHide}
                    onFilter={goToFilter}
                  />
                ) : undefined
              }
            />
          )}
        </div>

        <StatusBar
          live={live}
          loaded={loaded}
          queue={counts}
          downSpeed={totals.down}
          readOnly={BOOT.readOnly}
          onFilter={goToFilter}
          onPauseAll={pauseAll}
          onResumeAll={resumeAll}
          bandwidth={bandwidth.status === 'unsupported' ? null : bandwidth.state}
          bandwidthMenuOpen={menu?.owner === 'bandwidth'}
          onBandwidthMenu={openBandwidthMenu}
        />
      </div>

      {dialog}

      {helpOpen && <ShortcutsDialog onClose={() => setHelpOpen(false)} />}

      <ConfirmDialog request={confirmReq} onClose={() => setConfirmReq(null)} />
      <ContextMenu menu={menu} onClose={() => setMenu(null)} />
      <Toasts toasts={toasts} onDismiss={dismiss} onPause={pause} onResume={resume} />
    </>
  )
}
