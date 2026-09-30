import { useCallback } from 'react'
import { useTranslation } from 'react-i18next'
import type { ConfirmRequest } from '../components/ConfirmDialog'
import { api } from '../lib/api'
import type { RowAction } from '../lib/taskKind'
import type { ToastTone } from './useToasts'

interface Deps {
  refresh: () => Promise<void>
  toast: (message: string, tone?: ToastTone) => void
  confirm: (request: ConfirmRequest) => void
}

const CALL: Record<RowAction, (id: string) => Promise<void>> = {
  pause: api.pause,
  resume: api.resume,
  retry: api.retry,
}

/**
 * Task mutations, single and bulk. Bulk actions fan out to the same per-id endpoints — the
 * server has no batch API — and report once, after every call has settled. Removed rows leave
 * the caller's selection by themselves: the next snapshot prunes them.
 */
export function useTaskActions({ refresh, toast, confirm }: Deps) {
  const { t } = useTranslation()

  const doneToast = useCallback(
    (action: RowAction) =>
      toast({ pause: t('toast.paused'), resume: t('toast.resumed'), retry: t('toast.retried') }[action]),
    [toast, t],
  )

  const runAction = useCallback(
    async (id: string, action: RowAction) => {
      try {
        await CALL[action](id)
        doneToast(action)
        await refresh()
      } catch {
        // Already surfaced by the api layer.
      }
    },
    [refresh, doneToast],
  )

  const runBulk = useCallback(
    async (action: RowAction, ids: string[]) => {
      const results = await Promise.allSettled(ids.map((id) => CALL[action](id)))
      if (results.some((r) => r.status === 'fulfilled')) doneToast(action)
      await refresh()
    },
    [refresh, doneToast],
  )

  const remove = useCallback(
    async (ids: string[], withData: boolean) => {
      const results = await Promise.allSettled(ids.map((id) => api.remove(id, withData)))
      if (!results.some((r) => r.status === 'fulfilled')) return
      toast(withData ? t('toast.removedWithData') : t('toast.removed'), 'trash')
      await refresh()
    },
    [refresh, toast, t],
  )

  /** "Remove from list" is undoable by re-adding; "with data" deletes files, so it always asks. */
  const removeTask = useCallback(
    (id: string, withData: boolean) => {
      if (!withData) {
        void remove([id], false)
        return
      }
      confirm({
        title: t('confirm.removeDataTitle'),
        body: t('library.confirmRemoveWithData'),
        confirmLabel: t('menu.removeWithData'),
        onConfirm: () => void remove([id], true),
      })
    },
    [remove, confirm, t],
  )

  const removeMany = useCallback(
    (ids: string[]) => {
      confirm({
        title: t('confirm.removeManyTitle', { count: ids.length }),
        body: t('confirm.removeManyBody'),
        confirmLabel: t('common.remove'),
        onConfirm: () => void remove(ids, false),
      })
    },
    [remove, confirm, t],
  )

  return { runAction, runBulk, removeTask, removeMany }
}
