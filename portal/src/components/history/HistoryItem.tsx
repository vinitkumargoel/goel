import { memo } from 'react'
import { useTranslation } from 'react-i18next'
import { historyFileURL } from '../../lib/api'
import { fmtAbsolute, fmtSize } from '../../lib/format'
import type { DateGroup } from '../../lib/historyTools'
import { kindBadge } from '../../lib/taskKind'
import type { HistoryRow } from '../../lib/types'
import { Art } from '../ui/Art'
import { Icon } from '../ui/Icon'
import { entryTime, entryType, folderOf, hostOf } from './historyParts'

interface HistoryItemProps {
  entry: HistoryRow
  /** The date group it sits in: decides how its time reads. */
  group: DateGroup
  canWrite: boolean
  onReadd: (source: string) => void
  onRemove: (id: string) => void
  onCopy: (source: string) => void
  /** Opens the row's menu at the button. */
  onMore: (entry: HistoryRow, at: { x: number; y: number }) => void
  /** Present = select mode: the card carries a checkbox for bulk removal. */
  selected?: boolean
  onSelect?: (id: string, on: boolean) => void
}

/**
 * One finished download on the timeline: artwork, name, "PROTOCOL · host · size", the time it
 * landed, and its actions in place. Save works read-only too: it reads, it changes nothing.
 */
export const HistoryItem = memo(function HistoryItem({
  entry: e,
  group,
  canWrite,
  onReadd,
  onRemove,
  onCopy,
  onMore,
  selected,
  onSelect,
}: HistoryItemProps) {
  const { t } = useTranslation()
  const host = hostOf(e.source)
  const folder = folderOf(e.savePath)
  const meta = [kindBadge(e.kind), host, e.totalBytes != null ? fmtSize(e.totalBytes) : '']
    .filter(Boolean)
    .join(' · ')
  return (
    <li className={`hist-item${selected ? ' on' : ''}`}>
      {onSelect && (
        <input
          type="checkbox"
          className="check hist-check"
          checked={selected ?? false}
          aria-label={t('historyBulk.select', { name: e.name })}
          onChange={(ev) => onSelect(e.id, ev.target.checked)}
        />
      )}
      <Art kind={entryType(e)} size="s" />
      <div className="hist-tx">
        <span className="hist-nm" title={e.name}>
          {e.name}
        </span>
        <span className="hist-mt" title={folder ? t('pages.history.savedIn', { folder }) : undefined}>
          {meta}
        </span>
      </div>
      <time className="hist-time small muted" dateTime={new Date(e.completedAt * 1000).toISOString()} title={fmtAbsolute(e.completedAt)}>
        {entryTime(e.completedAt, group)}
      </time>
      <div className="hist-acts">
        {/* The server 404s a file that has since vanished from disk. */}
        <a
          className="ibtn sm b hist-wide"
          href={historyFileURL(e.id)}
          download
          aria-label={t('history.saveNamed', { name: e.name })}
          title={t('history.saveHint')}
        >
          <Icon name="download" size="s" />
        </a>
        {canWrite && (
          <button
            type="button"
            className="btn sm hist-wide"
            onClick={() => onReadd(e.source)}
            aria-label={t('history.readdNamed', { name: e.name })}
          >
            <Icon name="retry" size="s" />
            <span className="hist-lbl">{t('history.readd')}</span>
          </button>
        )}
        <button
          type="button"
          className="ibtn sm b hist-wide"
          onClick={() => onCopy(e.source)}
          aria-label={t('pages.history.copyNamed', { name: e.name })}
          title={t('common.copyLink')}
        >
          <Icon name="link" size="s" />
        </button>
        <button
          type="button"
          className="ibtn sm b"
          aria-haspopup="menu"
          aria-label={t('pages.history.moreNamed', { name: e.name })}
          title={t('pages.history.more')}
          onClick={(ev) => {
            const r = ev.currentTarget.getBoundingClientRect()
            onMore(e, { x: r.right - 220, y: r.bottom + 4 })
          }}
        >
          <Icon name="more" size="s" />
        </button>
        {canWrite && (
          <button
            type="button"
            className="ibtn sm b hist-wide hist-del"
            onClick={() => onRemove(e.id)}
            aria-label={t('history.removeNamed', { name: e.name })}
            title={t('pages.history.remove')}
          >
            <Icon name="trash" size="s" />
          </button>
        )}
      </div>
    </li>
  )
})
