import { useCallback, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { AddDialog } from '../components/AddDialog'
import type { AddSummary } from '../lib/addSubmit'
import { api, failureMessage } from '../lib/api'
import type { ToastTone } from './useToasts'
import { useWindowTorrentDrop } from './useWindowTorrentDrop'

interface Deps {
  canWrite: boolean
  toast: (message: string, tone?: ToastTone) => void
  refresh: () => Promise<void>
  /** Something was queued: show the library, unfiltered for a fresh add. */
  onQueued: (resetFilter: boolean) => void
}

/**
 * Everything that puts downloads in the queue: the Add dialog (opened by the button, "N", the
 * FAB, or a .torrent dropped on the window) and History's Re-add. `dialog` is the scrim + dialog
 * to render at the top level.
 */
export function useAddFlow({ canWrite, toast, refresh, onQueued }: Deps) {
  const { t } = useTranslation()
  const [open, setOpen] = useState(false)
  /** Torrent files dropped on the window; the dialog opens pre-filled with them. */
  const [dropped, setDropped] = useState<File[]>([])
  const warn = useCallback((message: string) => toast(message, 'warn'), [toast])

  const openAdd = useCallback(() => setOpen(true), [])
  const closeAdd = useCallback(() => {
    setOpen(false)
    setDropped([])
  }, [])

  useWindowTorrentDrop(canWrite && !open, (files) => {
    setDropped(files)
    setOpen(true)
  })

  const onAdded = useCallback(
    (summary: AddSummary) => {
      closeAdd()
      onQueued(true)
      if (summary.added > 0) toast(t('toast.added', { count: summary.added }))
      if (summary.refused > 0) warn(t('toast.refused', { count: summary.refused }))
      const files = summary.failures.filter((f) => f.file !== '')
      const first = files[0]
      if (first) {
        warn(t('toast.torrentFailed', { count: files.length, file: first.file, error: first.error }))
      }
      for (const f of summary.failures) if (f.file === '') warn(f.error)
      void refresh()
    },
    [closeAdd, onQueued, toast, warn, refresh, t],
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

  const dialog = (
    <div
      className={`scrim${open ? ' open' : ''}`}
      onClick={(e) => {
        if (e.target === e.currentTarget) closeAdd()
      }}
    >
      {open && <AddDialog onClose={closeAdd} onWarn={warn} onAdded={onAdded} initialFiles={dropped} />}
    </div>
  )

  return { addOpen: open, openAdd, closeAdd, readd, dialog }
}
