import { useCallback } from 'react'
import { useTranslation } from 'react-i18next'
import type { ConfirmRequest } from '../components/ConfirmDialog'
import { api, failureMessage } from '../lib/api'
import { BULK_CONCURRENCY, runPool, summariseBulk } from '../lib/bulk'
import type { RowAction } from '../lib/taskKind'
import type { ToastTone } from './useToasts'

interface Deps {
  refresh: () => Promise<void>
  toast: (message: string, tone?: ToastTone) => void
  confirm: (request: ConfirmRequest) => void
  /** Ids in the latest snapshot. Read when a confirmation is accepted, not when it was asked. */
  currentIds: () => ReadonlySet<string>
}

const CALL: Record<RowAction, (id: string) => Promise<void>> = {
  pause: (id) => api.pause(id),
  resume: (id) => api.resume(id),
  retry: (id) => api.retry(id),
}

type Verb = RowAction | 'remove'

/**
 * Task mutations, single and bulk. Bulk actions fan out to the same per-id endpoints — the
 * server has no batch API — at most `BULK_CONCURRENCY` at a time, and report once, after every
 * call has settled, with how many succeeded and failed. Removed rows leave the caller's
 * selection by themselves: the next snapshot prunes them.
 */
export function useTaskActions({ refresh, toast, confirm, currentIds }: Deps) {
  const { t } = useTranslation()

  /** One toast for a settled batch: success, "3 of 5 — 2 failed", or why nothing worked. */
  const report = useCallback(
    (verb: Verb, results: PromiseSettledResult<void>[], success: () => void) => {
      const outcome = summariseBulk(results)
      if (outcome.kind === 'ok') return success()
      if (outcome.kind === 'partial') {
        toast(t(`toast.bulkPartial.${verb}`, outcome), 'warn')
        return
      }
      // A null reason was already surfaced by the api layer (a 403 refusal, or a 401 redirect).
      if (outcome.reason == null) return
      toast(
        outcome.total === 1
          ? outcome.reason
          : t(`toast.bulkFailed.${verb}`, { count: outcome.total, reason: outcome.reason }),
        'warn',
      )
    },
    [toast, t],
  )

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
      } catch (e) {
        const message = failureMessage(e)
        if (message) toast(message, 'warn')
      }
      await refresh()
    },
    [refresh, doneToast, toast],
  )

  const runBulk = useCallback(
    async (action: RowAction, ids: string[]) => {
      const results = await runPool(ids, BULK_CONCURRENCY, (id) => CALL[action](id))
      report(action, results, () => doneToast(action))
      await refresh()
    },
    [refresh, doneToast, report],
  )

  const remove = useCallback(
    async (ids: string[], withData: boolean) => {
      // A confirmation can sit open across snapshots: anything removed meanwhile is not re-sent.
      const present = currentIds()
      const targets = ids.filter((id) => present.has(id))
      if (targets.length === 0) return
      const results = await runPool(targets, BULK_CONCURRENCY, (id) => api.remove(id, withData))
      report('remove', results, () =>
        toast(withData ? t('toast.removedWithData') : t('toast.removed'), 'trash'),
      )
      await refresh()
    },
    [refresh, toast, report, currentIds, t],
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
