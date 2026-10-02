import { useCallback, useEffect, useMemo, useRef } from 'react'
import { useTranslation } from 'react-i18next'
import { isStale } from '../components/shell/Banners'
import type { ConfirmRequest } from '../components/dialogs/ConfirmDialog'
import { setRefusalHandler } from '../lib/api'
import { copyText } from '../lib/clipboard'
import { withOptimisticStatus } from '../lib/optimistic'
import { useBandwidth } from './useBandwidth'
import { useNow } from './useNow'
import { useTaskActions } from './useTaskActions'
import { useTasks } from './useTasks'
import { useToasts } from './useToasts'

/**
 * The server side of the window: the live task list, toasts, bandwidth, the task actions, and
 * whether the stream has gone stale. Rows removed with an Undo still on screen are left out.
 */
export function useAppData(confirm: (request: ConfirmRequest | null) => void) {
  const { t } = useTranslation()
  const { tasks: snapshot, live, loaded, error, lastUpdate, refresh, reconnect } = useTasks()
  const toasts = useToasts()
  const { toast } = toasts
  const warn = useCallback((message: string) => toast(message, 'warn'), [toast])
  const bandwidth = useBandwidth()

  // Ticks only while the stream is down, for the banner's "0:14 ago".
  const now = useNow(1000, !live)
  const stale = isStale(live, lastUpdate, now)

  const tasksRef = useRef(snapshot)
  tasksRef.current = snapshot
  const currentIds = useCallback(() => new Set(tasksRef.current.map((task) => task.id)), [])
  const lookup = useCallback((id: string) => tasksRef.current.find((task) => task.id === id), [])

  const actions = useTaskActions({ refresh, toast, confirm, currentIds, lookup })
  const { hidden, inflight } = actions

  // A removal with its Undo still on screen is gone from every view, though the server has it yet.
  const visible = useMemo(
    () => (hidden.size === 0 ? snapshot : snapshot.filter((task) => !hidden.has(task.id))),
    [snapshot, hidden],
  )
  // A pause, resume or retry in flight shows its expected status at once; a failure drops it again.
  const tasks = useMemo(() => withOptimisticStatus(visible, inflight), [visible, inflight])

  useEffect(() => {
    setRefusalHandler(warn)
  }, [warn])

  const copy = useCallback(
    (text: string) => {
      void copyText(text).then((ok) =>
        ok ? toast(t('toast.copied'), 'copy') : toast(t('toast.copyFailed'), 'warn'),
      )
    },
    [toast, t],
  )

  return {
    tasks,
    live,
    loaded,
    error,
    lastUpdate,
    refresh,
    reconnect,
    toasts,
    toast,
    warn,
    copy,
    bandwidth,
    now,
    stale,
    actions,
  }
}
