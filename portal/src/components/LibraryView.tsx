import { memo } from 'react'
import { Trans, useTranslation } from 'react-i18next'
import { fmtSize, fmtSpeed, pct } from '../lib/format'
import { fileType, kindLabel, rowAction, type RowAction } from '../lib/taskKind'
import type { TaskRow } from '../lib/types'
import { DownloadIcon, FileTypeIcon, PauseIcon, PlayIcon, RetryIcon } from './Icons'

interface LibraryViewProps {
  tasks: TaskRow[]
  selectedId: string | null
  canWrite: boolean
  readOnly: boolean
  onSelect: (id: string) => void
  onAction: (id: string, action: RowAction) => void
  onContextMenu: (id: string, x: number, y: number) => void
}

export function LibraryView({
  tasks,
  selectedId,
  canWrite,
  readOnly,
  onSelect,
  onAction,
  onContextMenu,
}: LibraryViewProps) {
  const { t } = useTranslation()

  return (
    <div className="view">
      {readOnly && <div className="ro-banner">{t('library.readOnlyBanner')}</div>}

      {/* hide-* must match the cells below AND portal.css's ≤920px grid, or a label loses its column. */}
      <div className="lhead">
        <div>{t('library.colName')}</div>
        <div className="r">{t('library.colSize')}</div>
        <div className="hide-sm">{t('library.colStatus')}</div>
        <div className="r hide-xs">{t('library.colSpeed')}</div>
      </div>

      <div className="rows">
        {tasks.length === 0 ? (
          <div className="empty">
            <DownloadIcon />
            <h4>{t('library.emptyTitle')}</h4>
            <p>
              {/* The bolded word is the Add button's own label, so it has to come from that key. */}
              <Trans
                i18nKey="library.emptyBody"
                values={{ addLabel: t('common.add') }}
                components={{ bold: <b /> }}
              />
            </p>
          </div>
        ) : (
          tasks.map((task) => (
            <Row
              key={task.id}
              task={task}
              selected={task.id === selectedId}
              canWrite={canWrite}
              onSelect={onSelect}
              onAction={onAction}
              onContextMenu={onContextMenu}
            />
          ))
        )}
      </div>
    </div>
  )
}

interface RowProps {
  task: TaskRow
  selected: boolean
  canWrite: boolean
  onSelect: (id: string) => void
  onAction: (id: string, action: RowAction) => void
  onContextMenu: (id: string, x: number, y: number) => void
}

const Row = memo(function Row({
  task,
  selected,
  canWrite,
  onSelect,
  onAction,
  onContextMenu,
}: RowProps) {
  const { t } = useTranslation()
  const percent = pct(task.progress)
  const type = fileType(task)
  const action = rowAction(task.statusToken)

  return (
    <div
      className={`row${selected ? ' sel' : ''}`}
      onClick={() => onSelect(task.id)}
      onContextMenu={(e) => {
        e.preventDefault()
        onContextMenu(task.id, e.clientX, e.clientY)
      }}
    >
      <div className="c ncell">
        {action && canWrite ? (
          <button
            className="sbtn"
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
          <div style={{ width: 28 }} />
        )}

        <div className={`ftype ft-${type}`}>
          <FileTypeIcon type={type} />
        </div>

        <div className="nmeta">
          <div className="nline">
            <span className="ntext">{task.name}</span>
            <span className={`kb kb-${task.kind}`}>{kindLabel(task.kind).toUpperCase()}</span>
          </div>
          <div className={`mp ${task.statusToken}`}>
            <i style={{ width: `${percent}%` }} />
          </div>
        </div>
      </div>

      <div className="c r">{fmtSize(task.totalBytes)}</div>

      <div className="c hide-sm">
        <div className="scell">
          <span className={`sdot st-${task.statusToken}`} />
          <span className="stext">
            {task.status}
            {task.statusToken === 'downloading' && ` · ${percent.toFixed(0)}%`}
          </span>
        </div>
      </div>

      <div className="c r dspd hide-xs">{task.downSpeed > 0 ? fmtSpeed(task.downSpeed) : '—'}</div>
    </div>
  )
})

function ActionIcon({ action }: { action: RowAction }) {
  if (action === 'pause') return <PauseIcon />
  if (action === 'retry') return <RetryIcon />
  return <PlayIcon />
}
