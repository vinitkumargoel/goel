import { useCallback } from 'react'
import { useTranslation } from 'react-i18next'
import { eligibleFor } from '../components/BulkBar'
import type { MenuEntry, MenuState } from '../components/ContextMenu'
import {
  DownloadIcon,
  FileIcon,
  KeyboardIcon,
  LinkIcon,
  LogoutIcon,
  PauseIcon,
  PlayIcon,
  RecheckIcon,
  RetryIcon,
  StreamIcon,
  TrashIcon,
} from '../components/Icons'
import { api, failureMessage, streamURL } from '../lib/api'
import { BOOT } from '../lib/boot'
import { canSave, saveToDevice, saveURL } from '../lib/saveFile'
import type { SelectionAction } from '../lib/selection'
import { rowAction, type RowAction } from '../lib/taskKind'
import type { TaskRow } from '../lib/types'
import { useStableCallback } from './useStableCallback'
import type { ToastTone } from './useToasts'

const BULK_ACTIONS: readonly RowAction[] = ['pause', 'resume', 'retry']

function actionIcon(action: RowAction) {
  if (action === 'pause') return <PauseIcon />
  if (action === 'retry') return <RetryIcon />
  return <PlayIcon />
}

interface Deps {
  tasks: readonly TaskRow[]
  selectedIds: ReadonlySet<string>
  /** The selection as the user sees it: filtered and in on-screen order. */
  selectedVisible: readonly TaskRow[]
  canWrite: boolean
  select: (action: SelectionAction) => void
  openMenu: (menu: MenuState) => void
  copy: (text: string) => void
  toast: (message: string, tone?: ToastTone) => void
  runAction: (id: string, action: RowAction) => Promise<void>
  runBulk: (action: RowAction, ids: string[]) => Promise<void>
  removeTask: (id: string, withData: boolean) => void
  removeMany: (ids: string[]) => void
}

/**
 * The app's menus. The row context menu (right-click, "⋯", Shift+F10, the detail panel's "More"): on a row
 * inside a multi-selection it acts on the whole visible selection, as the bulk bar does.
 * `openRowMenu` has a stable identity so it never re-renders the memoised rows.
 */
export function useMenus(deps: Deps) {
  const { t } = useTranslation()
  const { removeTask } = deps

  const removeEntries = useCallback(
    (id: string): MenuEntry[] => [
      {
        key: 'rm',
        label: t('menu.removeFromList'),
        icon: <TrashIcon />,
        danger: true,
        shortcut: 'Del',
        action: () => removeTask(id, false),
      },
      {
        key: 'rmd',
        label: t('menu.removeWithData'),
        icon: <TrashIcon />,
        danger: true,
        action: () => removeTask(id, true),
      },
    ],
    [removeTask, t],
  )

  const bulkEntries = (rows: readonly TaskRow[]): MenuEntry[] => {
    const ids = rows.map((r) => r.id)
    const entries: MenuEntry[] = []
    if (deps.canWrite) {
      for (const action of BULK_ACTIONS) {
        const eligible = eligibleFor(rows, action)
        if (eligible.length === 0) continue
        entries.push({
          key: action,
          label: t(`bulk.${action}`, { count: eligible.length }),
          icon: actionIcon(action),
          shortcut: action === 'retry' ? undefined : 'Space',
          action: () => void deps.runBulk(action, eligible),
        })
      }
    }
    entries.push({
      key: 'copy',
      label: t('bulk.copyLinks'),
      icon: <LinkIcon />,
      action: () => deps.copy(rows.map((r) => r.source).join('\n')),
    })
    if (deps.canWrite) {
      entries.push(
        { separator: true },
        {
          key: 'rm',
          label: t('menu.removeMany', { count: ids.length }),
          icon: <TrashIcon />,
          danger: true,
          shortcut: 'Del',
          action: () => deps.removeMany(ids),
        },
      )
    }
    return entries
  }

  const singleEntries = (task: TaskRow): MenuEntry[] => {
    const id = task.id
    const entries: MenuEntry[] = []
    const action = rowAction(task.statusToken)
    if (deps.canWrite && action) {
      entries.push({
        key: 'act',
        label: t(`common.${action}`),
        icon: actionIcon(action),
        shortcut: action === 'retry' ? undefined : 'Space',
        action: () => void deps.runAction(id, action),
      })
    }
    entries.push({
      key: 'copy',
      label: t('menu.copySourceLink'),
      icon: <LinkIcon />,
      action: () => deps.copy(task.source),
    })
    if (canSave(task)) {
      entries.push({
        key: 'save',
        label: t('menu.saveToDevice'),
        icon: <DownloadIcon />,
        action: () => saveToDevice(saveURL(task), task.multiFile ? '' : task.name),
      })
    }
    if (task.streamable) {
      entries.push({
        key: 'stream',
        label: t('common.stream'),
        icon: <StreamIcon />,
        action: () => window.open(streamURL(id), '_blank', 'noopener,noreferrer'),
      })
    }
    if (deps.canWrite && task.kind === 'torrent') {
      entries.push({ separator: true })
      entries.push({
        key: 'recheck',
        label: t('menu.forceRecheck'),
        icon: <RecheckIcon />,
        action: () => {
          void api
            .recheck(id)
            .then(() => deps.toast(t('toast.rechecking')))
            .catch((e: unknown) => {
              const message = failureMessage(e)
              if (message) deps.toast(message, 'warn')
            })
        },
      })
    }
    if (deps.canWrite) entries.push({ separator: true }, ...removeEntries(id))
    return entries
  }

  /** `above` opens the menu upward from `y`, for a trigger at the bottom of the window. */
  const openRowMenu = useStableCallback((id: string, x: number, y: number, above?: boolean) => {
    const task = deps.tasks.find((t) => t.id === id)
    if (!task) return
    const inSelection = deps.selectedIds.has(id)
    if (!inSelection) deps.select({ type: 'single', id })

    const group = inSelection ? deps.selectedVisible : []
    if (group.length >= 2 && group.some((r) => r.id === id)) {
      deps.openMenu({ x, y, above, entries: bulkEntries(group), label: t('bulk.selected', { count: group.length }) })
      return
    }
    deps.openMenu({ x, y, above, entries: singleEntries(task), label: task.name })
  })

  /** The account menu under the topbar's user button. */
  const userMenu = useCallback(
    (anchor: DOMRect, openSettings: () => void, openShortcuts: () => void): MenuState => ({
      x: anchor.right - 210,
      y: anchor.bottom + 6,
      label: BOOT.username,
      entries: [
        { key: 'set', label: t('common.settings'), icon: <FileIcon />, action: openSettings },
        {
          key: 'keys',
          label: t('shortcuts.menuItem'),
          icon: <KeyboardIcon />,
          shortcut: '?',
          action: openShortcuts,
        },
        {
          key: 'out',
          label: t('common.signOut'),
          icon: <LogoutIcon />,
          danger: true,
          action: () => void api.logout(),
        },
      ],
    }),
    [t],
  )

  return { openRowMenu, removeEntries, userMenu }
}
