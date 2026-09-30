import { memo, useCallback, type MouseEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { fmtSize, fmtSpeed, pct } from '../lib/format'
import { fileType, kindBadge, kindLabel, rowAction, type RowAction } from '../lib/taskKind'
import type { TaskRow } from '../lib/types'
import { FileTypeIcon, MoreIcon, PauseIcon, PlayIcon, RetryIcon } from './Icons'

export interface RowClick {
  shift: boolean
  toggle: boolean
}

interface RowProps {
  task: TaskRow
  selected: boolean
  /** The one row in the roving tab order. */
  focusable: boolean
  canWrite: boolean
  /** Id of the "Shift+F10 for actions" hint. */
  describedBy?: string
  rowRef: (id: string, el: HTMLDivElement | null) => void
  onClick: (id: string, mods: RowClick) => void
  onAction: (id: string, action: RowAction) => void
  onMenu: (id: string, x: number, y: number) => void
}

export const LibraryRow = memo(function LibraryRow({
  task,
  selected,
  focusable,
  canWrite,
  describedBy,
  rowRef,
  onClick,
  onAction,
  onMenu,
}: RowProps) {
  const { t } = useTranslation()
  const percent = pct(task.progress)
  const whole = Math.round(percent)
  const type = fileType(task)
  const action = rowAction(task.statusToken)
  const statusText = `${task.status}${task.statusToken === 'downloading' ? ` · ${whole}%` : ''}`

  const id = task.id
  // Stable, or React detaches and re-attaches the ref on every render of the row.
  const ref = useCallback((el: HTMLDivElement | null) => rowRef(id, el), [rowRef, id])

  const openMenuAt = (e: MouseEvent<HTMLButtonElement>) => {
    e.stopPropagation()
    const r = e.currentTarget.getBoundingClientRect()
    onMenu(task.id, r.left, r.bottom + 4)
  }

  return (
    <div
      ref={ref}
      role="option"
      data-id={task.id}
      aria-selected={selected}
      aria-describedby={describedBy}
      aria-label={t('library.rowLabel', {
        name: task.name,
        kind: kindLabel(task.kind),
        status: task.status,
        percent: whole,
      })}
      tabIndex={focusable ? 0 : -1}
      className={`row${selected ? ' sel' : ''}`}
      onClick={(e) => onClick(task.id, { shift: e.shiftKey, toggle: e.metaKey || e.ctrlKey })}
      onContextMenu={(e) => {
        e.preventDefault()
        onMenu(task.id, e.clientX, e.clientY)
      }}
    >
      <div className="c ncell">
        {action && canWrite ? (
          // A pointer shortcut only. An option may not contain controls, so it is hidden from
          // assistive tech; the same action is in the bulk bar (shown for any selection) and the
          // row menu (Shift+F10), both reachable by keyboard and by touch screen readers.
          <button
            className="sbtn"
            tabIndex={-1}
            aria-hidden="true"
            aria-label={t(`common.${action}`)}
            onClick={(e) => {
              e.stopPropagation()
              onAction(task.id, action)
            }}
          >
            <ActionIcon action={action} />
          </button>
        ) : (
          // Keeps the name column aligned whether or not a button is there.
          <div className="sbtn-gap" />
        )}

        <div className={`ftype ft-${type}`}>
          <FileTypeIcon type={type} ink="currentColor" />
        </div>

        <div className="nmeta">
          <div className="nline">
            <span className="ntext">{task.name}</span>
            <span className={`kb kb-${task.kind}`} title={kindLabel(task.kind)}>
              {kindBadge(task.kind)}
            </span>
          </div>
          <div
            className={`mp ${task.statusToken}`}
            role="progressbar"
            aria-label={t('library.progress')}
            aria-valuemin={0}
            aria-valuemax={100}
            aria-valuenow={whole}
          >
            <i style={{ width: `${percent}%` }} />
          </div>
          {/* Only shown once the Status column is gone, so colour is never the only status cue. */}
          <div className="nstat">
            <span className={`sdot st-${task.statusToken}`} />
            <span className="stext">
              {statusText}
              {task.downSpeed > 0 && ` · ${fmtSpeed(task.downSpeed)}`}
            </span>
          </div>
        </div>

        <button
          className="rmore"
          tabIndex={-1}
          aria-hidden="true"
          aria-haspopup="menu"
          aria-label={t('library.moreActions', { name: task.name })}
          onClick={openMenuAt}
        >
          <MoreIcon />
        </button>
      </div>

      <div className="c r">{fmtSize(task.totalBytes)}</div>

      <div className="c hide-sm">
        <div className="scell">
          <span className={`sdot st-${task.statusToken}`} />
          <span className="stext">{statusText}</span>
        </div>
      </div>

      {/* Idle rows show nothing, as the native list does; upload gets a smaller second line. */}
      <div className="c r dspd hide-xs">
        {task.downSpeed > 0 && <div>{fmtSpeed(task.downSpeed)}</div>}
        {task.upSpeed > 0 && <div className="uspd">↑ {fmtSpeed(task.upSpeed)}</div>}
      </div>
    </div>
  )
})

function ActionIcon({ action }: { action: RowAction }) {
  if (action === 'pause') return <PauseIcon />
  if (action === 'retry') return <RetryIcon />
  return <PlayIcon />
}
