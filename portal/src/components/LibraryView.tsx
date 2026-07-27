import { memo } from 'react'
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
  return (
    <div className="view">
      {readOnly && (
        <div className="ro-banner">
          Read-only mode — viewing &amp; streaming only. Changes are disabled by the host.
        </div>
      )}

      {/* The hide-* classes must match the cells below exactly, and match the
          narrow-viewport `grid-template-columns` in portal.css: at ≤920px the
          grid drops to `1fr 96px 108px`, which is Status' width gone and Speed's
          kept, so Status is the `hide-sm` column. Getting these out of step
          leaves a header label with no column under it. */}
      <div className="lhead">
        <div>Name</div>
        <div className="r">Size</div>
        <div className="hide-sm">Status</div>
        <div className="r hide-xs">↓ Speed</div>
      </div>

      <div className="rows">
        {tasks.length === 0 ? (
          <div className="empty">
            <DownloadIcon />
            <h4>Nothing here</h4>
            <p>
              No downloads match this filter. Tap <b>Add</b> to queue a URL, magnet, or torrent.
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

/**
 * Memoised because the SSE stream replaces the whole task array several times a
 * second while downloads run. Without this every row re-renders on every
 * snapshot; with it, only rows whose own fields moved do.
 */
const Row = memo(function Row({
  task,
  selected,
  canWrite,
  onSelect,
  onAction,
  onContextMenu,
}: RowProps) {
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
            aria-label={action}
            onClick={(e) => {
              // The row underneath selects on click; the button must not do both.
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
