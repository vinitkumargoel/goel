import { useCallback, useEffect, useMemo, useReducer, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { AddDialog } from './components/AddDialog'
import { BulkBar } from './components/BulkBar'
import { ConfirmDialog, type ConfirmRequest } from './components/ConfirmDialog'
import { ContextMenu, type MenuEntry, type MenuState } from './components/ContextMenu'
import { DetailPanel } from './components/DetailPanel'
import type { DetailTab } from './components/DetailPanes'
import { HistoryView } from './components/HistoryView'
import {
  FileIcon,
  LinkIcon,
  LogoutIcon,
  PauseIcon,
  PlayIcon,
  RecheckIcon,
  RetryIcon,
  StreamIcon,
  TrashIcon,
} from './components/Icons'
import { LibraryView } from './components/LibraryView'
import { SettingsView } from './components/SettingsView'
import { Sidebar, type Filter, type View } from './components/Sidebar'
import { StatusBar } from './components/StatusBar'
import { Toasts } from './components/Toasts'
import { Topbar } from './components/Topbar'
import { useTaskActions } from './hooks/useTaskActions'
import { useTasks } from './hooks/useTasks'
import { useToasts } from './hooks/useToasts'
import { api, setRefusalHandler, streamURL } from './lib/api'
import { BOOT } from './lib/boot'
import { copyText } from './lib/clipboard'
import { countFilters, filterTasks } from './lib/filters'
import { EMPTY_SELECTION, selectionReducer } from './lib/selection'
import { nextSort, sortTasks, UNSORTED, type SortKey, type SortState } from './lib/sort'
import { rowAction } from './lib/taskKind'
import { applyTheme, initialTheme, type Theme } from './lib/theme'
import type { FilePriority, TaskDetail } from './lib/types'

const DETAIL_POLL_MS = 4000
const PANEL_BREAKPOINT = 920

export function App() {
  const { t } = useTranslation()
  const [view, setView] = useState<View>('library')
  const [filter, setFilter] = useState<Filter>('all')
  const [search, setSearch] = useState('')
  const [sort, setSort] = useState<SortState>(UNSORTED)
  const [selection, select] = useReducer(selectionReducer, EMPTY_SELECTION)
  const [detail, setDetail] = useState<TaskDetail | null>(null)
  const [tab, setTab] = useState<DetailTab>('general')
  const [panelOpen, setPanelOpen] = useState(() => window.innerWidth > PANEL_BREAKPOINT)
  const [sidebarOpen, setSidebarOpen] = useState(false)
  const [addOpen, setAddOpen] = useState(false)
  const [menu, setMenu] = useState<(MenuState & { owner: 'row' | 'user' }) | null>(null)
  const [confirmReq, setConfirmReq] = useState<ConfirmRequest | null>(null)
  const [theme, setTheme] = useState<Theme>(initialTheme)

  const { tasks, live, loaded, refresh } = useTasks()
  const { toasts, toast, dismiss, pause, resume } = useToasts()

  const canWrite = !BOOT.readOnly
  // The detail panel follows the lead row, and only while it is still selected.
  const detailId =
    selection.lead != null && selection.ids.has(selection.lead) ? selection.lead : null

  const { runAction, runBulk, removeTask, removeMany } = useTaskActions({
    refresh,
    toast,
    confirm: setConfirmReq,
  })

  useEffect(() => {
    setRefusalHandler((message) => toast(message, 'warn'))
  }, [toast])

  useEffect(() => {
    applyTheme(theme, false)
  }, [theme])

  // Crossing the breakpoint resets the panel to that layout's default; a toggle within one layout sticks.
  useEffect(() => {
    if (typeof window.matchMedia !== 'function') return
    const wide = window.matchMedia(`(min-width: ${PANEL_BREAKPOINT + 1}px)`)
    const onChange = (e: MediaQueryListEvent) => setPanelOpen(e.matches)
    wide.addEventListener('change', onChange)
    return () => wide.removeEventListener('change', onChange)
  }, [])

  const copy = useCallback(
    (text: string) => {
      void copyText(text).then((ok) =>
        ok ? toast(t('toast.copied'), 'copy') : toast(t('toast.copyFailed'), 'warn'),
      )
    },
    [toast, t],
  )

  const loadDetail = useCallback(async (id: string) => {
    try {
      setDetail(await api.task(id))
    } catch {
      setDetail(null)
    }
  }, [])

  useEffect(() => {
    if (detailId == null) {
      setDetail(null)
      return
    }
    void loadDetail(detailId)
  }, [detailId, loadDetail])

  // Without this the panel's progress bar only moves on the 4s refetch while the list behind it updates live.
  useEffect(() => {
    if (detailId == null) return
    const row = tasks.find((t) => t.id === detailId)
    if (!row) return
    setDetail((d) => (d && d.row.id === detailId ? { ...d, row } : d))
  }, [tasks, detailId])

  // A snapshot without a selected row means it was removed elsewhere; drop it from the selection.
  useEffect(() => {
    if (loaded) select({ type: 'prune', existing: tasks.map((t) => t.id) })
  }, [tasks, loaded])

  const detailPollRef = useRef<() => void>(() => {})
  detailPollRef.current = () => {
    if (detailId == null || view !== 'library' || !panelOpen) return
    const row = tasks.find((t) => t.id === detailId)
    if (!row || row.statusToken !== 'completed') void loadDetail(detailId)
  }
  useEffect(() => {
    const timer = setInterval(() => detailPollRef.current(), DETAIL_POLL_MS)
    return () => clearInterval(timer)
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

  const totals = useMemo(
    () =>
      tasks.reduce(
        (acc, t) => ({ down: acc.down + (t.downSpeed || 0), up: acc.up + (t.upSpeed || 0) }),
        { down: 0, up: 0 },
      ),
    [tasks],
  )

  const readd = useCallback(
    async (source: string) => {
      try {
        await api.add({ url: source })
        toast(t('toast.readded'))
        setView('library')
        await refresh()
      } catch {
        // Already surfaced by the api layer.
      }
    },
    [refresh, toast, t],
  )

  const setFilePriority = useCallback(
    async (fileId: number, priority: string) => {
      if (detailId == null) return
      try {
        await api.filePriority(detailId, fileId, priority)
        await loadDetail(detailId)
      } catch {
        // Already surfaced by the api layer.
      }
    },
    [detailId, loadDetail],
  )

  const cyclePriority = useCallback(
    (fileId: number, current: FilePriority) => {
      const order: FilePriority[] = ['low', 'normal', 'high']
      const next = order[(order.indexOf(current) + 1) % order.length]!
      void setFilePriority(fileId, next)
    },
    [setFilePriority],
  )

  const removeEntries = useCallback(
    (id: string): MenuEntry[] => [
      {
        key: 'rm',
        label: t('menu.removeFromList'),
        icon: <TrashIcon />,
        danger: true,
        action: () => removeTask(id, false),
      },
      {
        key: 'rmd',
        label: t('menu.removeWithData'),
        icon: <TrashIcon />,
        danger: true,
        action: () => removeTask(id, true),
      },
    ],
    [removeTask, t],
  )

  const openRowMenu = useCallback(
    (id: string, x: number, y: number) => {
      const task = tasks.find((t) => t.id === id)
      if (!task) return
      if (!selection.ids.has(id)) select({ type: 'single', id })

      const entries: MenuEntry[] = []
      const action = rowAction(task.statusToken)
      if (canWrite && action) {
        entries.push({
          key: 'act',
          label: t(`common.${action}`),
          icon: action === 'pause' ? <PauseIcon /> : action === 'retry' ? <RetryIcon /> : <PlayIcon />,
          action: () => void runAction(id, action),
        })
      }
      entries.push({
        key: 'copy',
        label: t('menu.copySourceLink'),
        icon: <LinkIcon />,
        action: () => copy(task.source),
      })
      if (task.streamable) {
        entries.push({
          key: 'stream',
          label: t('common.stream'),
          icon: <StreamIcon />,
          action: () => window.open(streamURL(id), '_blank', 'noopener,noreferrer'),
        })
      }
      if (canWrite && task.kind === 'torrent') {
        entries.push({ separator: true })
        entries.push({
          key: 'recheck',
          label: t('menu.forceRecheck'),
          icon: <RecheckIcon />,
          action: () => {
            void api
              .recheck(id)
              .then(() => toast(t('toast.rechecking')))
              .catch(() => {})
          },
        })
      }
      if (canWrite) {
        entries.push({ separator: true }, ...removeEntries(id))
      }
      setMenu({ x, y, entries, label: task.name, owner: 'row' })
    },
    [tasks, selection.ids, canWrite, copy, runAction, removeEntries, toast, t],
  )

  const openUserMenu = useCallback(
    (anchor: DOMRect) => {
      setMenu({
        x: anchor.right - 210,
        y: anchor.bottom + 6,
        owner: 'user',
        label: BOOT.username,
        entries: [
          {
            key: 'set',
            label: t('common.settings'),
            icon: <FileIcon />,
            action: () => setView('settings'),
          },
          {
            key: 'out',
            label: t('common.signOut'),
            icon: <LogoutIcon />,
            danger: true,
            action: () => void api.logout(),
          },
        ],
      })
    },
    [t],
  )

  const visibleIdsRef = useRef<string[]>([])
  visibleIdsRef.current = view === 'library' ? visible.map((task) => task.id) : []

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        setMenu(null)
        setAddOpen(false)
        setSidebarOpen(false)
        return
      }
      // ⌘/Ctrl+A with nothing focused selects the list; in a field it still selects text.
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === 'a' && document.activeElement === document.body) {
        if (visibleIdsRef.current.length === 0) return
        e.preventDefault()
        select({ type: 'all', order: visibleIdsRef.current })
      }
    }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [])

  const selectView = useCallback((next: View) => {
    setView(next)
    setSidebarOpen(false)
  }, [])

  const openDetail = useCallback(
    (id: string) => {
      select({ type: 'single', id })
      if (!panelOpen) setPanelOpen(true)
    },
    [panelOpen],
  )

  const onSort = useCallback((key: SortKey) => setSort((s) => nextSort(s, key)), [])

  return (
    <>
      <Topbar
        search={search}
        onSearch={setSearch}
        downSpeed={totals.down}
        upSpeed={totals.up}
        showPanelToggle={view === 'library'}
        panelOpen={panelOpen}
        onTogglePanel={() => setPanelOpen((p) => !p)}
        onAdd={() => setAddOpen(true)}
        onToggleSidebar={() => setSidebarOpen((s) => !s)}
        onUserMenu={openUserMenu}
        userMenuOpen={menu?.owner === 'user'}
        sidebarOpen={sidebarOpen}
        canWrite={canWrite}
      />

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
        />

        <main className="content">
          {view === 'library' && selectedVisible.length > 1 && (
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
              search={search}
              selectedIds={selection.ids}
              lead={selection.lead}
              sort={sort}
              canWrite={canWrite}
              readOnly={BOOT.readOnly}
              onSelection={select}
              onOpen={openDetail}
              onSort={onSort}
              onAction={(id, a) => void runAction(id, a)}
              onMenu={openRowMenu}
              onClearSearch={() => setSearch('')}
              onAdd={() => setAddOpen(true)}
            />
          )}
          {view === 'history' && (
            <HistoryView
              canWrite={canWrite}
              onReadd={readd}
              onRemoved={() => toast(t('toast.entryRemoved'), 'trash')}
            />
          )}
          {view === 'settings' && (
            <SettingsView
              theme={theme}
              onTheme={setTheme}
              canWrite={canWrite}
              onToast={(m) => toast(m)}
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
            onClose={() => setPanelOpen(false)}
            onAction={(id, a) => void runAction(id, a)}
            onRemove={(id, at) =>
              setMenu({ x: at.x, y: at.y + 4, entries: removeEntries(id), owner: 'row' })
            }
            onMore={(id, at) => openRowMenu(id, at.x, at.y)}
            onCopy={copy}
            onToggleFile={(fileId, wasSkipped) =>
              void setFilePriority(fileId, wasSkipped ? 'normal' : 'skip')
            }
            onCyclePriority={cyclePriority}
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
      />

      <div
        className={`scrim${addOpen ? ' open' : ''}`}
        onClick={(e) => {
          if (e.target === e.currentTarget) setAddOpen(false)
        }}
      >
        {addOpen && (
          <AddDialog
            onClose={() => setAddOpen(false)}
            onWarn={(m) => toast(m, 'warn')}
            onAdded={(added, refused) => {
              setAddOpen(false)
              setFilter('all')
              selectView('library')
              toast(t('toast.added', { count: added }))
              if (refused > 0) toast(t('toast.refused', { count: refused }), 'warn')
              void refresh()
            }}
          />
        )}
      </div>

      <ConfirmDialog request={confirmReq} onClose={() => setConfirmReq(null)} />
      <ContextMenu menu={menu} onClose={() => setMenu(null)} />
      <Toasts toasts={toasts} onDismiss={dismiss} onPause={pause} onResume={resume} />
    </>
  )
}
