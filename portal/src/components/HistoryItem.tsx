import { useTranslation } from 'react-i18next'
import { fmtAbsolute, fmtShortWhen, fmtSize, fmtWhen } from '../lib/format'
import { historyFileURL } from '../lib/api'
import { fileType, kindLabel } from '../lib/taskKind'
import type { HistoryRow } from '../lib/types'
import { ChevronDownIcon, DownloadIcon, FileTypeIcon, RetryIcon, TrashIcon } from './Icons'

interface HistoryItemProps {
  entry: HistoryRow
  canWrite: boolean
  /** A phone row: a short date that doesn't wrap under the name. */
  compact?: boolean
  onReadd: (source: string) => void
  onRemove: (id: string) => void
  /** Present = the row has a checkbox for bulk removal. */
  selected?: boolean
  onSelect?: (id: string, on: boolean) => void
  /** Opens the folder picker, then re-adds into the chosen folder. */
  onReaddTo?: (entry: HistoryRow) => void
}

export function HistoryItem({
  entry: e,
  canWrite,
  compact = false,
  onReadd,
  onRemove,
  selected,
  onSelect,
  onReaddTo,
}: HistoryItemProps) {
  const { t } = useTranslation()
  const type = fileType({ name: e.name, kind: e.kind, statusToken: '' })
  // `savePath` includes the file name, so the folder is the second-to-last component, not the last.
  const parts = e.savePath.split('/').filter(Boolean)
  const folder = parts.length >= 2 ? parts[parts.length - 2]! : ''
  return (
    <li className={`hrow${onSelect ? ' sel' : ''}${selected ? ' on' : ''}`}>
      {onSelect && (
        <input
          type="checkbox"
          className="hchk"
          checked={selected ?? false}
          aria-label={t('historyBulk.select', { name: e.name })}
          onChange={(ev) => onSelect(e.id, ev.target.checked)}
        />
      )}
      <div className={`hic ft-${type}`}>
        <FileTypeIcon type={type} ink="currentColor" />
      </div>
      <div style={{ minWidth: 0 }}>
        <div className="ntext">{e.name}</div>
        <div className="hsub" title={fmtAbsolute(e.completedAt)}>
          {kindLabel(e.kind)} · {compact ? fmtShortWhen(e.completedAt) : fmtWhen(e.completedAt)}
        </div>
      </div>
      <div className="c r hide-xs" style={{ color: 'var(--text-dim)' }}>
        {fmtSize(e.totalBytes)}
      </div>
      <div className="c r hide-sm hfolder">{folder}</div>
      <div className="hact">
        {/* Reading, not a change: read-only sessions may save too. The server 404s a vanished file. */}
        <a
          className="mbtn"
          href={historyFileURL(e.id)}
          download
          aria-label={t('history.saveNamed', { name: e.name })}
          title={t('history.saveHint')}
        >
          <DownloadIcon />
        </a>
        {canWrite && (
          <>
            <button
              className="mbtn"
              onClick={() => onReadd(e.source)}
              aria-label={t('history.readdNamed', { name: e.name })}
            >
              <RetryIcon />
              <span className="lbl">{t('history.readd')}</span>
            </button>
            {onReaddTo && (
              <button
                className="mbtn hsplit"
                onClick={() => onReaddTo(e)}
                aria-label={t('historyBulk.readdTo')}
                title={t('historyBulk.readdTo')}
              >
                <ChevronDownIcon aria-hidden="true" />
              </button>
            )}
            <button
              className="mbtn danger"
              onClick={() => onRemove(e.id)}
              aria-label={t('history.removeNamed', { name: e.name })}
            >
              <TrashIcon />
            </button>
          </>
        )}
      </div>
    </li>
  )
}
