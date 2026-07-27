import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import { AddDialog } from './components/AddDialog'
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
import {
  Sidebar,
  type Filter,
  type FilterCounts,
  type View,
} from './components/Sidebar'
import { Toasts } from './components/Toasts'
import { Topbar } from './components/Topbar'
import { useTasks } from './hooks/useTasks'
import { useToasts } from './hooks/useToasts'
import { api, setRefusalHandler, streamURL } from './lib/api'
import { BOOT } from './lib/boot'
import { copyText } from './lib/clipboard'
import { isActive, rowAction, type RowAction } from './lib/taskKind'
import { applyTheme, initialTheme, type Theme } from './lib/theme'
import type { FilePriority, TaskDetail } from './lib/types'

/** Heavy detail fields (peers, files) are not in the SSE snapshot; refetch them. */
const DETAIL_POLL_MS = 4000
/** Below this the detail panel starts closed — it would cover the whole list. */
const PANEL_BREAKPOINT = 920

export function App() {
  const [view, setView] = useState<View>('library')
  const [filter, setFilter] = useState<Filter>('all')
  const [search, setSearch] = useState('')
  const [selectedId, setSelectedId] = useState<string | null>(null)
  const [detail, setDetail] = useState<TaskDetail | null>(null)
  const [tab, setTab] = useState<DetailTab>('general')
  const [panelOpen, setPanelOpen] = useState(() => window.innerWidth > PANEL_BREAKPOINT)
  const [sidebarOpen, setSidebarOpen] = useState(false)
  const [addOpen, setAddOpen] = useState(false)
  const [menu, setMenu] = useState<MenuState | null>(null)
  const [theme, setTheme] = useState<Theme>(initialTheme)

  const { tasks, refresh } = useTasks()
  const { toasts, toast } = useToasts()

  const canWrite = !BOOT.readOnly

  // A refused request explains itself in the server's own words; route those to
  // a toast rather than letting each call site invent its own message.
  useEffect(() => {
    setRefusalHandler((message) => toast(message, 'warn'))
  }, [toast])

  useEffect(() => {
    applyTheme(theme, false)
  }, [theme])

  const copy = useCallback(
    (text: string) => {
      void copyText(text).then((ok) =>
        ok
          ? toast('Copied', 'copy')
          : toast('Couldn’t copy — select the text manually', 'warn'),
      )
    },
    [toast],
  )

  // ---- detail ----

  const loadDetail = useCallback(async (id: string) => {
    try {
      setDetail(await api.task(id))
    } catch {
      setDetail(null)
    }
  }, [])

  useEffect(() => {
    if (selectedId == null) {
      setDetail(null)
      return
    }
    void loadDetail(selectedId)
  }, [selectedId, loadDetail])

  // Keep the open detail's header row live from the SSE snapshot. Without this
  // the progress bar in the panel would only move on the 4s refetch while the
  // list behind it updates continuously.
  useEffect(() => {
    if (selectedId == null) return
    const row = tasks.find((t) => t.id === selectedId)
    if (!row) return
    setDetail((d) => (d && d.row.id === selectedId ? { ...d, row } : d))
  }, [tasks, selectedId])

  // Refetch the fields SSE does not carry. A completed task has no moving parts
  // left, so polling it is pure waste.
  const detailPollRef = useRef<() => void>(() => {})
  detailPollRef.current = () => {
    if (selectedId == null || view !== 'library' || !panelOpen) return
    const row = tasks.find((t) => t.id === selectedId)
    if (!row || row.statusToken !== 'completed') void loadDetail(selectedId)
  }
  useEffect(() => {
    const timer = setInterval(() => detailPollRef.current(), DETAIL_POLL_MS)
    return () => clearInterval(timer)
  }, [])

  // ---- derived ----

  const counts: FilterCounts = useMemo(() => {
    const c: FilterCounts = { all: tasks.length, active: 0, paused: 0, completed: 0, seeding: 0, failed: 0 }
    for (const t of tasks) {
      if (isActive(t.statusToken)) c.active++
      else if (t.statusToken === 'paused') c.paused++
      else if (t.statusToken === 'completed') c.completed++
      else if (t.statusToken === 'seeding') c.seeding++
      else if (t.statusToken === 'failed') c.failed++
    }
    return c
  }, [tasks])

  const visible = useMemo(() => {
    const needle = search.trim().toLowerCase()
    return tasks.filter((t) => {
      if (needle && !t.name.toLowerCase().includes(needle)) return false
      switch (filter) {
        case 'all':
          return true
        case 'active':
          return isActive(t.statusToken)
        default:
          return t.statusToken === filter
      }
    })
  }, [tasks, search, filter])

  const totals = useMemo(
    () =>
      tasks.reduce(
        (acc, t) => ({ down: acc.down + (t.downSpeed || 0), up: acc.up + (t.upSpeed || 0) }),
        { down: 0, up: 0 },
      ),
    [tasks],
  )

  // ---- actions ----

  const runAction = useCallback(
    async (id: string, action: RowAction) => {
      try {
        if (action === 'pause') await api.pause(id)
        else if (action === 'resume') await api.resume(id)
        else await api.retry(id)
        toast({ pause: 'Paused', resume: 'Resumed', retry: 'Retried' }[action])
        await refresh()
      } catch {
        // Already surfaced by the api layer.
      }
    },
    [refresh, toast],
  )

  const removeTask = useCallback(
    async (id: string, withData: boolean) => {
      if (
        withData &&
        !confirm(
          "Delete the downloaded files from disk too? This permanently removes them and can't be undone.",
        )
      ) {
        return
      }
      try {
        await api.remove(id, withData)
        if (selectedId === id) setSelectedId(null)
        toast(withData ? 'Removed with data' : 'Removed', 'trash')
        await refresh()
      } catch {
        // Already surfaced by the api layer.
      }
    },
    [refresh, selectedId, toast],
  )

  const readd = useCallback(
    async (source: string) => {
      try {
        await api.add({ url: source })
        toast('Re-added to queue')
        setView('library')
        await refresh()
      } catch {
        // Already surfaced by the api layer.
      }
    },
    [refresh, toast],
  )

  const setFilePriority = useCallback(
    async (fileId: number, priority: string) => {
      if (selectedId == null) return
      try {
        await api.filePriority(selectedId, fileId, priority)
        await loadDetail(selectedId)
      } catch {
        // Already surfaced by the api layer.
      }
    },
    [selectedId, loadDetail],
  )

  const cyclePriority = useCallback(
    (fileId: number, current: FilePriority) => {
      const order: FilePriority[] = ['low', 'normal', 'high']
      const next = order[(order.indexOf(current) + 1) % order.length]!
      void setFilePriority(fileId, next)
    },
    [setFilePriority],
  )

  // ---- menus ----

  const removeEntries = useCallback(
    (id: string): MenuEntry[] => [
      {
        key: 'rm',
        label: 'Remove from list',
        icon: <TrashIcon />,
        danger: true,
        action: () => void removeTask(id, false),
      },
      {
        key: 'rmd',
        label: 'Remove with data',
        icon: <TrashIcon />,
        danger: true,
        action: () => void removeTask(id, true),
      },
    ],
    [removeTask],
  )

  const openRowMenu = useCallback(
    (id: string, x: number, y: number) => {
      const task = tasks.find((t) => t.id === id)
      if (!task) return
      setSelectedId(id)

      const entries: MenuEntry[] = []
      const action = rowAction(task.statusToken)
      if (canWrite && action) {
        entries.push({
          key: 'act',
          label: action[0]!.toUpperCase() + action.slice(1),
          icon: action === 'pause' ? <PauseIcon /> : action === 'retry' ? <RetryIcon /> : <PlayIcon />,
          action: () => void runAction(id, action),
        })
      }
      entries.push({
        key: 'copy',
        label: 'Copy source link',
        icon: <LinkIcon />,
        action: () => copy(task.source),
      })
      if (task.streamable) {
        entries.push({
          key: 'stream',
          label: 'Stream',
          icon: <StreamIcon />,
          action: () => window.open(streamURL(id), '_blank', 'noopener,noreferrer'),
        })
      }
      if (canWrite && task.kind === 'torrent') {
        entries.push({ separator: true })
        entries.push({
          key: 'recheck',
          label: 'Force recheck',
          icon: <RecheckIcon />,
          action: () => {
            void api
              .recheck(id)
              .then(() => toast('Rechecking'))
              .catch(() => {})
          },
        })
      }
      if (canWrite) {
        entries.push({ separator: true }, ...removeEntries(id))
      }
      setMenu({ x, y, entries })
    },
    [tasks, canWrite, copy, runAction, removeEntries, toast],
  )

  const openUserMenu = useCallback((anchor: DOMRect) => {
    setMenu({
      x: anchor.right - 210,
      y: anchor.bottom + 6,
      entries: [
        { key: 'set', label: 'Settings', icon: <FileIcon />, action: () => setView('settings') },
        {
          key: 'out',
          label: 'Sign out',
          icon: <LogoutIcon />,
          danger: true,
          action: () => void api.logout(),
        },
      ],
    })
  }, [])

  // ---- keyboard ----

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return
      setMenu(null)
      setAddOpen(false)
    }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [])

  // ---- render ----

  const selectView = useCallback((next: View) => {
    setView(next)
    setSidebarOpen(false)
  }, [])

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

        <div className="content">
          {view === 'library' && (
            <LibraryView
              tasks={visible}
              selectedId={selectedId}
              canWrite={canWrite}
              readOnly={BOOT.readOnly}
              onSelect={(id) => {
                setSelectedId(id)
                if (!panelOpen) setPanelOpen(true)
              }}
              onAction={(id, a) => void runAction(id, a)}
              onContextMenu={openRowMenu}
            />
          )}
          {view === 'history' && (
            <HistoryView canWrite={canWrite} onReadd={readd} onRemoved={() => toast('Entry removed', 'trash')} />
          )}
          {view === 'settings' && (
            <SettingsView
              theme={theme}
              onTheme={setTheme}
              canWrite={canWrite}
              onToast={(m) => toast(m)}
            />
          )}
        </div>

        {view === 'library' && (
          <DetailPanel
            detail={detail}
            open={panelOpen}
            tab={tab}
            canWrite={canWrite}
            onTab={setTab}
            onClose={() => setPanelOpen(false)}
            onAction={(id, a) => void runAction(id, a)}
            onRemove={(id, at) => setMenu({ x: at.x - 160, y: at.y + 6, entries: removeEntries(id) })}
            onCopy={copy}
            onToggleFile={(fileId, wasSkipped) =>
              void setFilePriority(fileId, wasSkipped ? 'normal' : 'skip')
            }
            onCyclePriority={cyclePriority}
          />
        )}
      </div>

      <div className="statusbar">
        <span className="sb-dim">
          {tasks.length} download{tasks.length === 1 ? '' : 's'}
        </span>
        <div className="sp" />
        <span className="sb-dim">
          Signed in · <span>{BOOT.username}</span>
        </span>
      </div>

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
              toast(added > 1 ? `Added ${added} downloads` : 'Added to queue')
              if (refused > 0) toast(`${refused} refused — internal network address`, 'warn')
              void refresh()
            }}
          />
        )}
      </div>

      <ContextMenu menu={menu} onClose={() => setMenu(null)} />
      <Toasts toasts={toasts} />
    </>
  )
}
