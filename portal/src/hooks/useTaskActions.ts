import { useCallback, useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import type { ConfirmRequest } from '../components/dialogs/ConfirmDialog'
import { api, failureMessage, removeOnUnload } from '../lib/api'
import { BULK_CONCURRENCY, runPool, summariseBulk } from '../lib/bulk'
import { fmtSize } from '../lib/format'
import { removalSummary } from '../lib/removal'
import type { RowAction } from '../lib/taskKind'
import type { TaskRow } from '../lib/types'
import { UNDO_MS, type ToastOptions, type ToastTone } from './useToasts'

interface Deps {
  refresh: () => Promise<void>
  toast: (message: string, tone?: ToastTone, options?: ToastOptions) => unknown
  confirm: (request: ConfirmRequest) => void
  /** Ids in the latest snapshot. Read when a confirmation is accepted, not when it was asked. */
  currentIds: () => ReadonlySet<string>
  /** The row for an id, for names and sizes in a confirmation or an Undo toast. */
  lookup?: (id: string) => TaskRow | undefined
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
export function useTaskActions({ refresh, toast, confirm, currentIds, lookup }: Deps) {
  const { t } = useTranslation()
  /** Rows removed with an Undo still on screen: hidden now, sent to the server when the toast goes. */
  const [hidden, setHidden] = useState<ReadonlySet<string>>(() => new Set())
  const pending = useRef(new Set<string>())

  const unhide = useCallback((id: string) => {
    setHidden((current) => {
      if (!current.has(id)) return current
      const next = new Set(current)
      next.delete(id)
      return next
    })
  }, [])

  // Closing the tab mid-Undo still removes: the choice was made, only the call was waiting.
  useEffect(() => {
    const flush = () => {
      for (const id of pending.current) removeOnUnload(id)
      pending.current.clear()
    }
    window.addEventListener('pagehide', flush)
    return () => window.removeEventListener('pagehide', flush)
  }, [])

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

  /** Sends a removal whose Undo window has closed. The row stays hidden until the snapshot drops it. */
  const commitRemoval = useCallback(
    async (id: string) => {
      if (!pending.current.delete(id)) return
      try {
        await api.remove(id, false)
      } catch (e) {
        const message = failureMessage(e)
        if (message) toast(message, 'warn')
      }
      await refresh()
      unhide(id)
    },
    [refresh, toast, unhide],
  )

  /**
   * "Remove from list" happens at once on screen with an Undo; the call waits for the toast to go.
   * "With data" deletes files, so it always asks first and is never deferred.
   */
  const removeTask = useCallback(
    (id: string, withData: boolean) => {
      if (!withData) {
        if (pending.current.has(id)) return
        pending.current.add(id)
        setHidden((current) => new Set(current).add(id))
        const name = lookup?.(id)?.name
        toast(name ? t('workflow.toast.removedNamed', { name }) : t('toast.removed'), 'trash', {
          ms: UNDO_MS,
          action: {
            label: t('workflow.toast.undo'),
            run: () => {
              pending.current.delete(id)
              unhide(id)
            },
          },
          onClose: (reason) => {
            if (reason !== 'action') void commitRemoval(id)
          },
        })
        return
      }
      // Name what is about to be deleted, with its size when the server knows it.
      const task = lookup?.(id)
      confirm({
        title: t('confirm.removeDataTitle'),
        body: t('library.confirmRemoveWithData'),
        items: task ? [{ name: task.name, bytes: task.totalBytes ?? task.doneBytes, kind: task.kind }] : undefined,
        confirmLabel: t('menu.removeWithData'),
        onConfirm: () => void remove([id], true),
      })
    },
    [remove, confirm, t, toast, lookup, unhide, commitRemoval],
  )

  const removeMany = useCallback(
    (ids: string[]) => {
      const summary = removalSummary(ids.map((id) => lookup?.(id)), ids.length)
      const size = fmtSize(summary.bytes)
      confirm({
        title: t('confirm.removeManyTitle', { count: ids.length }),
        body: t('workflow.confirm.removeManyBody'),
        items: summary.names,
        footnote:
          summary.more > 0
            ? t('workflow.confirm.moreAndSize', { count: summary.more, size })
            : t('workflow.confirm.totalSize', { size }),
        confirmLabel: t('workflow.confirm.removeN', { count: ids.length }),
        option: {
          label: t('workflow.confirm.alsoDelete'),
          confirmLabel: t('workflow.confirm.deleteN', { count: ids.length, size }),
        },
        onConfirm: (withData) => void remove(ids, withData),
      })
    },
    [remove, confirm, t, lookup],
  )

  /** Server-side "all": covers tasks the filter hides, unlike a bulk action on the selection. */
  const runAll = useCallback(
    async (verb: 'pause' | 'resume') => {
      try {
        await (verb === 'pause' ? api.pauseAll() : api.resumeAll())
        toast(verb === 'pause' ? t('statusbar.pausedAll') : t('statusbar.resumedAll'))
      } catch (e) {
        const message = failureMessage(e)
        if (message) toast(message, 'warn')
      }
      await refresh()
    },
    [refresh, toast, t],
  )

  const pauseAll = useCallback(() => void runAll('pause'), [runAll])
  const resumeAll = useCallback(() => void runAll('resume'), [runAll])

  return { runAction, runBulk, removeTask, removeMany, pauseAll, resumeAll, hidden }
}
