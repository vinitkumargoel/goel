import { useId, useState } from 'react'
import { useTranslation } from 'react-i18next'
import type { ReviewRow, ReviewTotals } from '../../lib/addReview'
import { fmtSize } from '../../lib/format'
import { kindBadge, kindLabel } from '../../lib/taskKind'
import { Art } from '../ui/Art'
import { Icon } from '../ui/Icon'
import { lineHost, reviewTypes, rowType, STATUS_PILL, visibleRows, type ReviewFilter } from './addHelpers'

interface AddReviewProps {
  rows: readonly ReviewRow[]
  checked: ReadonlySet<number>
  onToggle: (index: number, on: boolean) => void
  filter: ReviewFilter
  onFilter: (filter: ReviewFilter) => void
  /** Torrent files going alongside the links; listed, always sent. */
  torrentNames: readonly string[]
  /** The footer's status line, which describes the list. */
  footId: string
}

/**
 * The Add dialog's second step: what each pasted line turned out to be, ticked or not. A magnet or
 * torrent the server could open lists its files; choosing among them happens after adding, in the
 * Files tab, since the add call takes whole downloads.
 */
export function AddReview({ rows, checked, onToggle, filter, onFilter, torrentNames, footId }: AddReviewProps) {
  const { t } = useTranslation()
  const types = reviewTypes(rows)
  const shown = visibleRows(rows, filter)
  return (
    <>
      {types.length > 1 && (
        <div className="add-filters" role="group" aria-label={t('sidebar.type')}>
          <button
            type="button"
            className={`chip sm${filter === 'all' ? ' on' : ''}`}
            aria-pressed={filter === 'all'}
            onClick={() => onFilter('all')}
          >
            {t('adding.all')} <span className="n">{rows.length}</span>
          </button>
          {types.map(({ type, count }) => (
            <button
              key={type}
              type="button"
              className={`chip sm${filter === type ? ' on' : ''}`}
              aria-pressed={filter === type}
              onClick={() => onFilter(type)}
            >
              {t(`fileType.${type}`)} <span className="n">{count}</span>
            </button>
          ))}
        </div>
      )}
      <ul className="add-rv" aria-describedby={footId}>
        {shown.map((row) => (
          <ReviewItem key={row.index} row={row} checked={checked.has(row.index)} onToggle={onToggle} />
        ))}
        {torrentNames.map((name) => (
          <li key={`t:${name}`} className="add-rv-row">
            <input type="checkbox" className="check" checked disabled aria-label={name} />
            <Art kind="magnet" size="s" />
            <span className="col add-rv-name">
              <b className="ell" title={name}>
                {name}
              </b>
            </span>
            <span className="badge">BT</span>
            <span className="mono small faint add-rv-size">—</span>
            <span className="pill good add-rv-pill">{t('workflow.add.status.torrentFile')}</span>
          </li>
        ))}
      </ul>
    </>
  )
}

function ReviewItem({
  row,
  checked,
  onToggle,
}: {
  row: ReviewRow
  checked: boolean
  onToggle: (index: number, on: boolean) => void
}) {
  const { t } = useTranslation()
  const [open, setOpen] = useState(false)
  const filesId = useId()
  const hasFiles = row.files.length > 0
  const host = lineHost(row.text) ?? (/^magnet:/i.test(row.text) ? t('adding.magnetLink') : null)
  const on = row.addable && checked
  const checkId = useId()
  return (
    <li className={`add-rv-row${row.addable ? '' : ' off'}`}>
      <input
        id={checkId}
        type="checkbox"
        className="check"
        checked={on}
        disabled={!row.addable}
        aria-label={row.name}
        onChange={(e) => onToggle(row.index, e.target.checked)}
      />
      <Art kind={row.addable ? rowType(row) : 'ghost'} size="s" faded={!on} />
      {/* The name ticks the row too: a finger-sized target on a phone. */}
      <label className="col add-rv-name" htmlFor={checkId}>
        <b className={`ell${on ? '' : ' faint'}`} title={row.text}>
          {row.name}
        </b>
        <span className="tiny faint ell">{[host, row.note].filter(Boolean).join(' · ')}</span>
      </label>
      <span className="badge" title={row.kind ? kindLabel(row.kind) : undefined}>
        {row.kind ? kindBadge(row.kind) : '—'}
      </span>
      <span className={`mono small add-rv-size${row.totalBytes == null ? ' faint' : ''}`}>
        {row.totalBytes != null ? `${row.estimated ? '~' : ''}${fmtSize(row.totalBytes)}` : '—'}
      </span>
      <span className={`${STATUS_PILL[row.status]} add-rv-pill`}>{t(`workflow.add.status.${row.status}`)}</span>
      {hasFiles && (
        <button
          type="button"
          className="btn sm ghost add-rv-more"
          aria-expanded={open}
          aria-controls={filesId}
          aria-label={t('workflow.add.showFiles', { count: row.fileCount, name: row.name })}
          onClick={() => setOpen((o) => !o)}
        >
          {t('workflow.add.files', { count: row.fileCount })}
          <Icon name={open ? 'chevronUp' : 'chevronDown'} size="s" />
        </button>
      )}
      {hasFiles && open && (
        <ul id={filesId} className="add-rv-files small">
          {row.files.map((f, i) => (
            <li key={i}>
              <span className="ell" title={f.name}>
                {f.name}
              </span>
              <span className="mono faint">{fmtSize(f.size)}</span>
            </li>
          ))}
          {row.fileCount > row.files.length && (
            <li className="faint">{t('workflow.add.moreFiles', { count: row.fileCount - row.files.length })}</li>
          )}
          <li className="help">{t('workflow.add.filesHint')}</li>
        </ul>
      )}
    </li>
  )
}

/** The review footer's "Total X · Y free in Z": a warning when the ticked rows won't fit. */
export function ReviewFoot({
  id,
  totals,
  freeBytes,
  folderLabel,
}: {
  id: string
  totals: ReviewTotals
  freeBytes: number | null
  folderLabel: string
}) {
  const { t } = useTranslation()
  const total = fmtSize(totals.bytes)
  return (
    <p id={id} className={`add-foot small${totals.short ? ' short' : ''}`} role="status">
      <Icon name={totals.short ? 'alert' : 'check'} size="s" className={totals.short ? 'badc' : 'goodc'} />
      <span>
        {freeBytes == null
          ? t('workflow.add.totalOnly', { count: totals.count, size: total })
          : t('workflow.add.totalFree', { count: totals.count, size: total, free: fmtSize(freeBytes), folder: folderLabel })}
        {totals.unsized > 0 && ` · ${t('workflow.add.unsized', { count: totals.unsized })}`}
        {totals.short && ` — ${t('workflow.add.short')}`}
      </span>
    </p>
  )
}
