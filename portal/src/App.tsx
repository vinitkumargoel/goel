import { useCallback, useEffect, useMemo, useReducer, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { BulkBar } from './components/BulkBar'
import { ConfirmDialog, type ConfirmRequest } from './components/ConfirmDialog'
import { ContextMenu, type MenuState } from './components/ContextMenu'
import { DetailPanel } from './components/DetailPanel'
import type { DetailTab } from './components/DetailPanes'
import { HistoryView } from './components/HistoryView'
import { LibraryView } from './components/LibraryView'
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
import { useStableCallback } from './hooks/useStableCallback'
import { useTaskActions } from './hooks/useTaskActions'
import { useTasks } from './hooks/useTasks'
import { useThemeChoice } from './hooks/useThemeChoice'
import { useToasts } from './hooks/useToasts'
import { setRefusalHandler } from './lib/api'
import { BOOT } from './lib/boot'
import { copyText } from './lib/clipboard'
import { countFilters, filterTasks } from './lib/filters'
import { EMPTY_SELECTION, selectionReducer } from './lib/selection'
import { nextSort, sortTasks, UNSORTED, type SortKey, type SortState } from './lib/sort'
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
  const [view, setView] = useState<View>('library')
  const [filter, setFilter] = useState<Filter>('all')
  const [search, setSearch] = useState('')
  const [sort, setSort] = useState<SortState>(UNSORTED)
  const [selection, select] = useReducer(selectionReducer, EMPTY_SELECTION)
  const [tab, setTab] = useState<DetailTab>('general')
  const [panelOpen, setPanelOpen] = useState(() => window.innerWidth > PANEL_BREAKPOINT)
  const [sidebarOpen, setSidebarOpen] = useState(false)
  const [menu, setMenu] = useState<AppMenu | null>(null)
  const [confirmReq, setConfirmReq] = useState<ConfirmRequest | null>(null)
  const [helpOpen, setHelpOpen] = useState(false)
  const [theme, setTheme] = useThemeChoice()
  const hamburgerRef = useRef<HTMLButtonElement>(null)
  const { searchRef, mobileSearch, setMobileSearch, focusSearch } = useSearchFocus()

  const { tasks, live, loaded, error, lastUpdate, speeds, refresh, reconnect } = useTasks()
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

  const { detail, setFilePriority, cyclePriority } = useDetail(
    detailId,
    tasks,
    view === 'library' && panelOpen,
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

  const selectView = useCallback((next: View) => {
    setView(next)
    setSidebarOpen(false)
  }, [])

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
      setView('library')
      focusSearch()
    },
    openHelp: () => setHelpOpen(true),
    rowElement,
  })

  const onRowAction = useCallback((id: string, a: RowAction) => void runAction(id, a), [runAction])

  const onSort = useCallback((key: SortKey) => setSort((s) => nextSort(s, key)), [])

  const clearSearch = useCallback(() => {
    setSearch('')
    setFilter('all')
  }, [])

  /** Closing from inside the panel would strand focus in an inert region: hand it back to the row. */
  const closePanel = useCallback(() => {
    setPanelOpen(false)
    if (detailId != null) rowElement(detailId)?.focus()
  }, [detailId])

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
          speedSamples={speeds.total}
          showPanelToggle={view === 'library'}
          panelOpen={panelOpen}
          onTogglePanel={() => setPanelOpen((p) => !p)}
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
            onSelectFilter={(f) => {
              setFilter(f)
              selectView('library')
            }}
            onSelectView={selectView}
            onClose={() => setSidebarOpen(false)}
            returnFocusTo={hamburgerRef}
          />

          <main className="content">
            {/* Also shown for one row: it is where touch screen-reader users reach a row's actions. */}
            {view === 'library' && selectedVisible.length > 0 && (
              <BulkBar
                selected={selectedVisible}
                canWrite={canWrite}
                onAction={(action, ids) => void runBulk(action, ids)}
                onCopyLinks={(sources) => copy(sources.join('\n'))}
                onRemove={removeMany}
                onClear={() => select({ type: 'clear' })}
              />
            )}
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
              />
            )}
          </main>

          {view === 'library' && (
            <DetailPanel
              detail={detail}
              open={panelOpen}
              tab={tab}
              canWrite={canWrite}
              onTab={setTab}
              onClose={closePanel}
              onAction={onRowAction}
              onRemove={(id, at) => openMenu({ x: at.x, y: at.y + 4, entries: removeEntries(id) })}
              onMore={(id, at) => openRowMenu(id, at.x, at.y)}
              onCopy={copy}
              onToggleFile={(fileId, wasSkipped) =>
                void setFilePriority(fileId, wasSkipped ? 'normal' : 'skip')
              }
              onCyclePriority={cyclePriority}
              samples={detailId != null ? speeds.perTask.get(detailId) : undefined}
              trapFocus={!modalOpen}
            />
          )}
        </div>

        <StatusBar
          live={live}
          loaded={loaded}
          active={counts.active}
          downSpeed={totals.down}
          upSpeed={totals.up}
          readOnly={BOOT.readOnly}
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
