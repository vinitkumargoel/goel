import { useEffect, useRef } from 'react'
import { useTranslation } from 'react-i18next'
import { documentTitle, statusMap, summarise, transitions } from '../lib/activity'
import { drawFavicon } from '../lib/favicon'
import { showNotification } from '../lib/notify'
import type { StatusToken, TaskRow } from '../lib/types'
import type { ToastOptions, ToastTone } from './useToasts'

/**
 * Everything that tells a user in another tab how the queue is doing: the tab title, the favicon
 * ring and badge, an in-app toast and (opted in) a system notification when a download finishes
 * or fails. `loaded` gates the first diff so a page load never announces old news.
 */
export function useActivitySignals({
  tasks,
  loaded,
  toast,
  onShow,
}: {
  tasks: readonly TaskRow[]
  loaded: boolean
  toast: (message: string, tone?: ToastTone, options?: ToastOptions) => void
  /** Select the download and open its panel — a notification click lands on it. */
  onShow: (id: string) => void
}) {
  const { t } = useTranslation()
  const previous = useRef<Map<string, StatusToken> | null>(null)

  useEffect(() => {
    const a = summarise(tasks)
    document.title = documentTitle(a, (count) => t('activity.titleActive', { count }))
    drawFavicon(a.active > 0 ? (a.progress ?? 0) : null, a.failed > 0)
  }, [tasks, t])

  useEffect(() => {
    if (!loaded) return
    const { finished, failed } = transitions(previous.current, tasks)
    previous.current = statusMap(tasks)
    for (const task of finished) {
      const show = { action: { label: t('activity.show'), run: () => onShow(task.id) } }
      toast(t('activity.finished', { name: task.name }), 'ok', show)
      showNotification(t('activity.notifyFinished'), task.name, () => onShow(task.id))
    }
    for (const task of failed) {
      const show = { action: { label: t('activity.show'), run: () => onShow(task.id) } }
      toast(t('activity.failed', { name: task.name }), 'warn', show)
      // `task.error` is the daemon's own message — passed through, not localized here.
      showNotification(t('activity.notifyFailed', { name: task.name }), task.error ?? '', () =>
        onShow(task.id),
      )
    }
  }, [tasks, loaded, toast, t, onShow])

  // Put the static title and icon back when the app unmounts (tests, hot reload).
  useEffect(
    () => () => {
      document.title = 'Goel°'
      drawFavicon(null, false)
    },
    [],
  )
}
