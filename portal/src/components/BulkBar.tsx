import { useTranslation } from 'react-i18next'
import { rowAction, type RowAction } from '../lib/taskKind'
import type { TaskRow } from '../lib/types'
import { CloseIcon, LinkIcon, PauseIcon, PlayIcon, RetryIcon, TrashIcon } from './Icons'

interface BulkBarProps {
  selected: TaskRow[]
  canWrite: boolean
  onAction: (action: RowAction, ids: string[]) => void
  onCopyLinks: (sources: string[]) => void
  onRemove: (ids: string[]) => void
  onClear: () => void
  /** Touch select mode: a Done button ends it instead of the ✕ clearing the selection. */
  onDone?: () => void
  className?: string
}

/** Rows in the selection that the given per-row action applies to right now. */
export function eligibleFor(selected: readonly TaskRow[], action: RowAction): string[] {
  return selected.filter((t) => rowAction(t.statusToken) === action).map((t) => t.id)
}

/**
 * Shown for a selection of two or more, in the column header's slot. A single row's actions live in
 * the detail panel (Enter opens it) and the row menu (Shift+F10), both keyboard and screen-reader
 * reachable. Every action fans out to the existing per-id endpoints; a button only appears when a
 * selected row can take it.
 */
export function BulkBar({
  selected,
  canWrite,
  onAction,
  onCopyLinks,
  onRemove,
  onClear,
  onDone,
  className,
}: BulkBarProps) {
  const { t } = useTranslation()
  const pause = eligibleFor(selected, 'pause')
  const resume = eligibleFor(selected, 'resume')
  const retry = eligibleFor(selected, 'retry')

  return (
    <div className={`bulkbar${className ? ` ${className}` : ''}`} role="toolbar" aria-label={t('bulk.toolbar')}>
      <span className="bcount" aria-live="polite">
        {t('bulk.selected', { count: selected.length })}
      </span>
      {canWrite && pause.length > 0 && (
        <button className="mbtn" onClick={() => onAction('pause', pause)}>
          <PauseIcon />
          {t('bulk.pause', { count: pause.length })}
        </button>
      )}
      {canWrite && resume.length > 0 && (
        <button className="mbtn" onClick={() => onAction('resume', resume)}>
          <PlayIcon />
          {t('bulk.resume', { count: resume.length })}
        </button>
      )}
      {canWrite && retry.length > 0 && (
        <button className="mbtn" onClick={() => onAction('retry', retry)}>
          <RetryIcon />
          {t('bulk.retry', { count: retry.length })}
        </button>
      )}
      {selected.length > 0 && (
        <button className="mbtn" onClick={() => onCopyLinks(selected.map((t) => t.source))}>
          <LinkIcon />
          {selected.length === 1 ? t('common.copyLink') : t('bulk.copyLinks')}
        </button>
      )}
      {canWrite && selected.length > 0 && (
        <button className="mbtn danger" onClick={() => onRemove(selected.map((t) => t.id))}>
          <TrashIcon />
          {t('common.remove')}
        </button>
      )}
      <div className="sp" />
      {onDone ? (
        <button className="mbtn done" onClick={onDone}>
          {t('workflow.library.done')}
        </button>
      ) : (
        <button className="mbtn" onClick={onClear} aria-label={t('bulk.clear')}>
          <CloseIcon />
        </button>
      )}
    </div>
  )
}
