import { useTranslation } from 'react-i18next'
import { fmtSize, fmtWhen } from '../lib/format'
import { fileType, kindLabel } from '../lib/taskKind'
import type { HistoryRow } from '../lib/types'
import { FileTypeIcon, RetryIcon, TrashIcon } from './Icons'

interface HistoryItemProps {
  entry: HistoryRow
  canWrite: boolean
  onReadd: (source: string) => void
  onRemove: (id: string) => void
}

export function HistoryItem({ entry: e, canWrite, onReadd, onRemove }: HistoryItemProps) {
  const { t } = useTranslation()
  const type = fileType({ name: e.name, kind: e.kind, statusToken: '' })
  // `savePath` includes the file name, so the folder is the second-to-last component, not the last.
  const parts = e.savePath.split('/').filter(Boolean)
  const folder = parts.length >= 2 ? parts[parts.length - 2]! : ''
  return (
    <li className="hrow">
      <div className={`hic ft-${type}`}>
        <FileTypeIcon type={type} ink="currentColor" />
      </div>
      <div style={{ minWidth: 0 }}>
        <div className="ntext">{e.name}</div>
        <div className="hsub">
          {kindLabel(e.kind)} · {fmtWhen(e.completedAt)}
        </div>
      </div>
      <div className="c r hide-xs" style={{ color: 'var(--text-dim)' }}>
        {fmtSize(e.totalBytes)}
      </div>
      <div className="c r hide-sm hfolder">{folder}</div>
      <div className="hact">
        {canWrite && (
          <>
            <button
              className="mbtn"
              onClick={() => onReadd(e.source)}
              aria-label={t('history.readdNamed', { name: e.name })}
            >
              <RetryIcon />
              {t('history.readd')}
            </button>
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
