import { useCallback, useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { AddDialog } from '../components/add/AddDialog'
import { clearDraft, loadDraft, type AddDraft } from '../lib/addDraft'
import { loadAddPrefs } from '../lib/addPrefs'
import { submitAdd, type AddSummary } from '../lib/addSubmit'
import { api, failureMessage } from '../lib/api'
import { summarizeLinks } from '../lib/links'
import type { ToastOptions, ToastTone } from './useToasts'
import { afterHistorySettles } from './useBackToClose'
import { useWindowTorrentDrop } from './useWindowTorrentDrop'

interface Deps {
  canWrite: boolean
  toast: (message: string, tone?: ToastTone, options?: ToastOptions) => unknown
  refresh: () => Promise<void>
  /** Something was queued: show the library, unfiltered for a fresh add. */
  onQueued: (resetFilter: boolean) => void
  /** Select and scroll to these new rows; also the added toast's Show. */
  onReveal?: (ids: string[]) => void
}

/**
 * Everything that puts downloads in the queue: the Add dialog (opened by the button, "N", the
 * FAB, or a .torrent dropped on the window) and History's Re-add. `dialog` is the scrim + dialog
 * to render at the top level.
 */
export function useAddFlow({ canWrite, toast, refresh, onQueued, onReveal }: Deps) {
  const { t } = useTranslation()
  const [open, setOpen] = useState(false)
  /** Torrent files dropped on the window; the dialog opens pre-filled with them. */
  const [dropped, setDropped] = useState<File[]>([])
  /** What the dialog held when a 401 cut it off; it reopens with it once, after signing back in. */
  const [draft, setDraft] = useState<AddDraft | null>(null)
  /** Links the dialog opens with, e.g. a URL pasted outside any field. */
  const [prefill, setPrefill] = useState<{ url: string; pasted: boolean } | null>(null)
  const warn = useCallback((message: string) => toast(message, 'warn'), [toast])

  useEffect(() => {
    const saved = loadDraft()
    if (!saved) return
    if (!canWrite) {
      clearDraft()
      return
    }
    setDraft(saved)
    setOpen(true)
    toast(t('toast.draftRestored'))
    // Once, at load: a later open starts from a clean dialog.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const openAdd = useCallback(() => setOpen(true), [])
  /** Opens with these links filled in; `pasted` says they came from the clipboard. */
  const openAddWith = useCallback((url: string, pasted = false) => {
    setPrefill({ url, pasted })
    setOpen(true)
  }, [])
  const closeAdd = useCallback(() => {
    setOpen(false)
    setDropped([])
    setDraft(null)
    setPrefill(null)
    clearDraft()
  }, [])

  useWindowTorrentDrop(canWrite && !open, (files) => {
    setDropped(files)
    setOpen(true)
  })

  const onAdded = useCallback(
    (summary: AddSummary) => {
      closeAdd()
      onQueued(true)
      const ids = summary.ids
      const show =
        onReveal && ids.length > 0
          ? { action: { label: t('workflow.toast.show'), run: () => onReveal(ids) } }
          : undefined
      if (summary.added > 0) toast(t('toast.added', { count: summary.added }), 'ok', show)
      if (summary.refused > 0) warn(t('toast.refused', { count: summary.refused }))
      const files = summary.failures.filter((f) => f.file !== '')
      const first = files[0]
      if (first) {
        warn(t('toast.torrentFailed', { count: files.length, file: first.file, error: first.error }))
      }
      for (const f of summary.failures) if (f.file === '') warn(f.error)
      // After the refresh, so the new rows exist to be selected rather than pruned as unknown.
      // …and after the dialog's history entry is gone, or landing on it would reselect the old row.
      void refresh()
        .then(afterHistorySettles)
        .then(() => {
          if (ids.length > 0) onReveal?.(ids)
        })
    },
    [closeAdd, onQueued, toast, warn, refresh, t, onReveal],
  )

  /**
   * The omnibox's Add: queues typed links straight away with the remembered folder and priority.
   * If the server turns them down, the dialog opens with them so they can be fixed there.
   */
  const quickAdd = useCallback(
    async (text: string) => {
      const prefs = loadAddPrefs()
      try {
        const summary = await submitAdd({
          text,
          validLinks: summarizeLinks(text).valid,
          files: [],
          options: { folder: prefs.folder || undefined, priority: prefs.priority },
        })
        onAdded(summary)
      } catch (e) {
        const message = failureMessage(e)
        if (message) warn(message)
        openAddWith(text)
      }
    },
    [onAdded, warn, openAddWith],
  )

  const readd = useCallback(
    async (source: string) => {
      try {
        await api.add({ url: source })
        toast(t('toast.readded'))
        onQueued(false)
        await refresh()
      } catch (e) {
        // Null for a 403 or 401: the api layer has already reported those.
        const message = failureMessage(e)
        if (message) warn(message)
      }
    },
    [refresh, toast, warn, onQueued, t],
  )

  // AddDialog is a Modal: it brings its own scrim, and closing it unmounts it.
  const dialog = open ? (
    <AddDialog
      onClose={closeAdd}
      onWarn={warn}
      onAdded={onAdded}
      initialFiles={dropped}
      initialDraft={draft}
      initialUrl={prefill?.url}
      pasted={prefill?.pasted}
    />
  ) : null

  return { addOpen: open, openAdd, openAddWith, quickAdd, closeAdd, readd, dialog }
}
