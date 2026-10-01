import type { TFunction } from 'i18next'
import type { MenuEntry } from '../components/ContextMenu'
import { ArrowDownIcon, ArrowUpIcon, ClockIcon, DownloadIcon, ListIcon } from '../components/Icons'
import { fmtAbsolute, fmtSpeed } from '../lib/format'
import type { StatusToken, TaskRow } from '../lib/types'
import type { QueueControls } from './useQueueControls'

/** Waiting its turn, so its place in line means something. */
const WAITING: ReadonlySet<StatusToken> = new Set<StatusToken>(['queued', 'paused'])
/** Still has bytes to fetch: a per-download cap or a start time can matter. */
const UNFINISHED: ReadonlySet<StatusToken> = new Set<StatusToken>(['queued', 'paused', 'downloading', 'metadata', 'failed'])

/** The row menu's queue section for one download: speed limit, place in line, tags, start time. */
export function queueEntries(task: TaskRow, queue: QueueControls, t: TFunction): MenuEntry[] {
  const entries: MenuEntry[] = [{ separator: true }]
  if (UNFINISHED.has(task.statusToken) || task.speedLimit) {
    entries.push({
      key: 'speed',
      label: t('queue.speedMenu'),
      detail: task.speedLimit ? fmtSpeed(task.speedLimit) : undefined,
      icon: <DownloadIcon />,
      action: () => queue.edit({ kind: 'speed', task }),
    })
  }
  if (WAITING.has(task.statusToken)) {
    entries.push(
      {
        key: 'top',
        label: t('queue.moveTop'),
        icon: <ArrowUpIcon />,
        action: () => queue.move([task.id], 'top'),
      },
      {
        key: 'bottom',
        label: t('queue.moveBottom'),
        icon: <ArrowDownIcon />,
        action: () => queue.move([task.id], 'bottom'),
      },
      {
        key: 'start',
        label: t('queue.startMenu'),
        detail: task.startAt ? fmtAbsolute(task.startAt) : undefined,
        icon: <ClockIcon />,
        action: () => queue.edit({ kind: 'start', task }),
      },
    )
  }
  entries.push({
    key: 'tags',
    label: t('queue.tagsMenu'),
    detail: task.tags?.length ? task.tags.join(', ') : undefined,
    icon: <ListIcon />,
    action: () => queue.edit({ kind: 'tags', task }),
  })
  return entries
}

/** Several rows: only the moves make sense for all of them at once. */
export function bulkQueueEntries(rows: readonly TaskRow[], queue: QueueControls, t: TFunction): MenuEntry[] {
  const waiting = rows.filter((r) => WAITING.has(r.statusToken)).map((r) => r.id)
  if (waiting.length === 0) return []
  return [
    { separator: true },
    {
      key: 'top',
      label: t('queue.moveTopMany', { count: waiting.length }),
      icon: <ArrowUpIcon />,
      action: () => queue.move(waiting, 'top'),
    },
    {
      key: 'bottom',
      label: t('queue.moveBottomMany', { count: waiting.length }),
      icon: <ArrowDownIcon />,
      action: () => queue.move(waiting, 'bottom'),
    },
  ]
}
