import { useCallback, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { QueueDialog, type QueueEdit } from '../components/dialogs/QueueDialogs'
import { api, failureMessage } from '../lib/api'
import { fmtSpeed } from '../lib/format'
import type { QueuePlacement, TaskRow, TrackerEdit } from '../lib/types'
import type { ToastTone } from './useToasts'

export interface QueueControls {
  /** Opens one of the small editors (speed limit, tags, start time, custom cap). */
  edit: (edit: QueueEdit) => void
  move: (ids: readonly string[], to: QueuePlacement, anchor?: string) => void
  setSequential: (id: string, on: boolean) => void
  setTags: (task: TaskRow, tags: string[]) => void
  setStartAt: (task: TaskRow, at: Date | null) => void
  /** Resolves true when the server took it, so an inline editor knows whether to close. */
  editTrackers: (body: TrackerEdit) => Promise<boolean>
}

/**
 * Per-download controls over the Remote API: each change refetches the list (and the open detail)
 * so what is shown is what the server now holds. Failures surface as a warning toast; a 403 has
 * already been reported by the api layer.
 */
export function useQueueControls({
  tasks,
  toast,
  refresh,
  reload,
}: {
  tasks: readonly TaskRow[]
  toast: (message: string, tone?: ToastTone) => void
  refresh: () => void | Promise<void>
  reload: () => void | Promise<void>
}) {
  const { t } = useTranslation()
  const [editing, setEditing] = useState<QueueEdit | null>(null)

  const run = useCallback(
    async (work: () => Promise<void>, done?: string) => {
      try {
        await work()
        if (done) toast(done, 'ok')
      } catch (e) {
        const message = failureMessage(e)
        if (message) toast(message, 'warn')
      } finally {
        void refresh()
        void reload()
      }
    },
    [toast, refresh, reload],
  )

  const setSpeed = useCallback(
    (task: TaskRow, bps: number | null) =>
      void run(
        () => api.setSpeedLimit(task.id, bps),
        bps ? t('queue.speedSet', { rate: fmtSpeed(bps) }) : t('queue.speedCleared'),
      ),
    [run, t],
  )

  const setTags = useCallback(
    (task: TaskRow, tags: string[]) => void run(() => api.setTags(task.id, tags)),
    [run],
  )

  const setStartAt = useCallback(
    (task: TaskRow, at: Date | null) =>
      void run(() => api.setStartAt(task.id, at ? at.getTime() / 1000 : null)),
    [run],
  )

  const controls: QueueControls = useMemo(
    () => ({
      edit: setEditing,
      move: (ids, to, anchor) => void run(() => api.move(ids, to, anchor)),
      setSequential: (id, on) => void run(() => api.setSequential(id, on)),
      setTags,
      setStartAt,
      editTrackers: async (body) => {
        let ok = false
        await run(async () => {
          await api.editTrackers(body)
          ok = true
        })
        return ok
      },
    }),
    [run, setTags, setStartAt],
  )

  const dialog = (
    <QueueDialog
      edit={editing}
      tasks={tasks}
      onClose={() => setEditing(null)}
      handlers={{ onSpeed: setSpeed, onTags: setTags, onStart: setStartAt }}
    />
  )

  return { controls, dialog, editing: editing != null }
}
