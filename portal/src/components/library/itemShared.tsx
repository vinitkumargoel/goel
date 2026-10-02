import type { TFunction } from 'i18next'
import type { MouseEvent, ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { fmtEta, pct } from '../../lib/format'
import type { TaskGroup } from '../../lib/grouping'
import { kindLabel, type RowAction } from '../../lib/taskKind'
import type { TaskRow } from '../../lib/types'
import { Icon, type IconName } from '../ui/Icon'

/** The modifiers of a click on a card or row. */
export interface ItemClick {
  shift: boolean
  toggle: boolean
}

/** What every card and table row takes from the list around it. */
export interface ItemProps {
  task: TaskRow
  selected: boolean
  /** The one item in the roving tab order. */
  focusable: boolean
  canWrite: boolean
  /**
   * ≤600px: the item's action button is announced (touch screen readers have no Shift+F10), and
   * there is no ⋯ button: a tap opens the detail sheet, which holds every action.
   */
  phone: boolean
  /** Touch select mode: a checkbox leads the item and a tap toggles it. */
  selecting: boolean
  /** Minute-resolution clock for relative times. */
  now: number
  /** Id of the "Shift+F10 for actions" hint. */
  describedBy: string
  itemRef: (id: string, el: HTMLElement | null) => void
  onClick: (id: string, mods: ItemClick) => void
  onAction: (id: string, action: RowAction) => void
  onMenu: (id: string, x: number, y: number) => void
  onStream?: (task: TaskRow) => void
}

export const ACTION_ICON: Readonly<Record<RowAction, IconName>> = {
  pause: 'pause',
  resume: 'play',
  retry: 'retry',
}

/** The status in the portal's language; the server's English copy is only the fallback. */
export function statusLabel(task: Pick<TaskRow, 'status' | 'statusToken'>, t: TFunction): string {
  return t(`workflow.group.status.${task.statusToken}`, { defaultValue: task.status })
}

/** The reason a failed download gives, or null. */
export function failureOf(task: TaskRow): string | null {
  return task.statusToken === 'failed' && task.error ? task.error : null
}

/** The option's accessible name: what it is, how it is doing. */
export function itemLabel(task: TaskRow, t: TFunction): string {
  const failure = failureOf(task)
  return failure
    ? t('library.rowLabelFailed', { name: task.name, kind: kindLabel(task.kind), error: failure })
    : t('library.rowLabel', {
        name: task.name,
        kind: kindLabel(task.kind),
        status: statusLabel(task, t),
        percent: Math.round(pct(task.progress)),
      })
}

/**
 * The status as a sentence fragment. The server's own wording leads; a running download says when,
 * not how far (the bar already shows that), and a few states add the one figure they are about.
 */
export function statusText(task: TaskRow, t: TFunction): string {
  const label = statusLabel(task, t)
  const whole = Math.round(pct(task.progress))
  switch (task.statusToken) {
    case 'downloading': {
      const eta = fmtEta(task.etaSeconds)
      return `${label} · ${eta ? t('library.left', { eta }) : `${whole}%`}`
    }
    case 'paused':
      return `${label} · ${whole}%`
    case 'queued':
      return task.queuePosition != null ? `${label} · #${task.queuePosition + 1}` : label
    case 'seeding':
      return t('board.card.seeding', { ratio: task.ratio.toFixed(2) })
    default:
      return label
  }
}

/** A Group by section's title: the status, the date bucket, or the host. */
export function groupTitle(group: TaskGroup, t: TFunction): string {
  if (group.by === 'status') return t(`workflow.group.status.${group.key}`, { defaultValue: group.key })
  if (group.by === 'added') return t(`history.groups.${group.key}`, { defaultValue: group.key })
  return group.key || t('workflow.group.noHost')
}

/** The attributes that make a card or a row an option of the library listbox. */
export function optionProps(p: ItemProps, t: TFunction) {
  const { task } = p
  return {
    role: 'option',
    'data-id': task.id,
    'aria-selected': p.selected,
    'aria-keyshortcuts': 'Space Enter Control+Space Meta+Space',
    'aria-describedby': p.describedBy,
    'aria-label': itemLabel(task, t),
    tabIndex: p.focusable ? 0 : -1,
    onClick: (e: MouseEvent) => p.onClick(task.id, { shift: e.shiftKey, toggle: e.metaKey || e.ctrlKey }),
    onContextMenu: (e: MouseEvent) => {
      e.preventDefault()
      p.onMenu(task.id, e.clientX, e.clientY)
    },
  } as const
}

interface ItemButtonProps {
  /** What the button does ("Pause"); on a phone it is announced with the item's name. */
  label: string
  name: string
  phone: boolean
  className: string
  onPress: (e: MouseEvent<HTMLButtonElement>) => void
  children: ReactNode
}

/**
 * A button inside a card or row. An option may not contain controls, so on a desktop it is a
 * pointer shortcut hidden from assistive tech (the same action is in the row menu, Shift+F10, and
 * the selection bar). On a phone it is announced, but stays out of the tab order: the item is it.
 */
export function ItemButton({ label, name, phone, className, onPress, children }: ItemButtonProps) {
  const { t } = useTranslation()
  return (
    <button
      type="button"
      className={className}
      tabIndex={-1}
      aria-hidden={phone ? undefined : true}
      aria-label={phone ? t('library.actionNamed', { action: label, name }) : label}
      title={label}
      onClick={(e) => {
        e.stopPropagation()
        onPress(e)
      }}
    >
      {children}
    </button>
  )
}

/** The ⋯ button: the row menu for a mouse. Pointer-only, like every in-item button on a desktop. */
export function MoreButton({ task, onMenu, className }: { task: TaskRow; onMenu: ItemProps['onMenu']; className: string }) {
  const { t } = useTranslation()
  return (
    <button
      type="button"
      className={className}
      tabIndex={-1}
      aria-hidden="true"
      aria-haspopup="menu"
      aria-label={t('library.moreActions', { name: task.name })}
      onClick={(e) => {
        e.stopPropagation()
        const r = e.currentTarget.getBoundingClientRect()
        onMenu(task.id, r.left, r.bottom + 4)
      }}
    >
      <Icon name="more" size="s" />
    </button>
  )
}

/** The select-mode tick. Decorative: aria-selected already says it. */
export function SelectTick({ on, className }: { on: boolean; className: string }) {
  return <span className={`check${on ? ' on' : ''} ${className}`} aria-hidden="true" />
}
