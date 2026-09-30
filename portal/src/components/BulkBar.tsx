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
}

/** Rows in the selection that the given per-row action applies to right now. */
export function eligibleFor(selected: readonly TaskRow[], action: RowAction): string[] {
  return selected.filter((t) => rowAction(t.statusToken) === action).map((t) => t.id)
}

/**
 * Shown for any selection, including a single row: it is how keyboard and touch screen-reader
 * users reach a row's actions, since a listbox option cannot contain buttons. Every action fans
 * out to the existing per-id endpoints; a button only appears when a selected row can take it.
 */
export function BulkBar({ selected, canWrite, onAction, onCopyLinks, onRemove, onClear }: BulkBarProps) {
  const { t } = useTranslation()
  const pause = eligibleFor(selected, 'pause')
  const resume = eligibleFor(selected, 'resume')
  const retry = eligibleFor(selected, 'retry')

  return (
    <div className="bulkbar" role="toolbar" aria-label={t('bulk.toolbar')}>
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
      <button className="mbtn" onClick={() => onCopyLinks(selected.map((t) => t.source))}>
        <LinkIcon />
        {selected.length === 1 ? t('common.copyLink') : t('bulk.copyLinks')}
      </button>
      {canWrite && (
        <button className="mbtn danger" onClick={() => onRemove(selected.map((t) => t.id))}>
          <TrashIcon />
          {t('common.remove')}
        </button>
      )}
      <div className="sp" />
      <button className="mbtn" onClick={onClear} aria-label={t('bulk.clear')}>
        <CloseIcon />
      </button>
    </div>
  )
}
