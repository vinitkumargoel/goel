import { useId, useState } from 'react'
import { useTranslation } from 'react-i18next'
import type { ReviewRow, ReviewTotals } from '../lib/addReview'
import { fmtSize } from '../lib/format'
import { fileType, kindBadge, kindLabel } from '../lib/taskKind'
import { ChevronDownIcon, FileTypeIcon } from './Icons'

interface AddReviewProps {
  rows: readonly ReviewRow[]
  checked: ReadonlySet<number>
  onToggle: (index: number, on: boolean) => void
  /** Torrent files going alongside the links; listed, always sent. */
  torrentNames: readonly string[]
  totals: ReviewTotals
  freeBytes: number | null
  /** Where the adds land, as the folder field shows it. */
  folderLabel: string
}

/**
 * The Add dialog's second step: what each pasted line turned out to be, ticked or not, and whether
 * it fits. A magnet or torrent the server could open lists its files; choosing among them happens
 * after adding, in the Files tab, since the add call takes whole downloads.
 */
export function AddReview({
  rows,
  checked,
  onToggle,
  torrentNames,
  totals,
  freeBytes,
  folderLabel,
}: AddReviewProps) {
  const { t } = useTranslation()
  const footId = useId()
  const total = fmtSize(totals.bytes)
  return (
    <>
      <ul className="rvlist" aria-describedby={footId}>
        {rows.map((row) => (
          <ReviewItem key={row.index} row={row} checked={checked.has(row.index)} onToggle={onToggle} />
        ))}
        {torrentNames.map((name) => (
          <li key={`t:${name}`} className="rvrow">
            <input type="checkbox" checked disabled aria-label={name} />
            <span className="ftype ft-magnet rvic">
              <FileTypeIcon type="magnet" ink="currentColor" />
            </span>
            <span className="rvname" title={name}>
              {name}
            </span>
            <span className="rvsize">—</span>
            <span className="rvbadge ok">{t('workflow.add.status.torrentFile')}</span>
          </li>
        ))}
      </ul>
      <p id={footId} className={`rvfoot${totals.short ? ' short' : ''}`} role="status">
        {freeBytes == null
          ? t('workflow.add.totalOnly', { count: totals.count, size: total })
          : t('workflow.add.totalFree', {
              count: totals.count,
              size: total,
              free: fmtSize(freeBytes),
              folder: folderLabel,
            })}
        {totals.unsized > 0 && ` · ${t('workflow.add.unsized', { count: totals.unsized })}`}
        {totals.short && ` — ${t('workflow.add.short')}`}
      </p>
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
  const type = fileType({ name: row.name, kind: row.kind ?? 'http', statusToken: '' })
  const hasFiles = row.files.length > 0
  const badge = STATUS_BADGE[row.status]
  return (
    <li className={`rvrow${row.addable ? '' : ' off'}`}>
      <input
        type="checkbox"
        checked={row.addable && checked}
        disabled={!row.addable}
        aria-label={row.name}
        onChange={(e) => onToggle(row.index, e.target.checked)}
      />
      <span className={`ftype ft-${type} rvic`}>
        <FileTypeIcon type={type} ink="currentColor" />
      </span>
      <span className="rvname" title={row.text}>
        {row.name}
        {row.kind && (
          <span className={`kb kb-${row.kind}`} title={kindLabel(row.kind)}>
            {kindBadge(row.kind)}
          </span>
        )}
        {row.note && <span className="rvnote">{row.note}</span>}
      </span>
      <span className="rvsize">
        {row.totalBytes != null ? `${row.estimated ? '~' : ''}${fmtSize(row.totalBytes)}` : '—'}
      </span>
      <span className={`rvbadge ${badge}`}>{t(`workflow.add.status.${row.status}`)}</span>
      {hasFiles && (
        <button
          type="button"
          className="rvmore"
          aria-expanded={open}
          aria-controls={filesId}
          aria-label={t('workflow.add.showFiles', { count: row.fileCount, name: row.name })}
          onClick={() => setOpen((o) => !o)}
        >
          {t('workflow.add.files', { count: row.fileCount })}
          <ChevronDownIcon aria-hidden="true" />
        </button>
      )}
      {hasFiles && open && (
        <ul id={filesId} className="rvfiles">
          {row.files.map((f, i) => (
            <li key={i}>
              <span className="rvname" title={f.name}>
                {f.name}
              </span>
              <span className="rvsize">{fmtSize(f.size)}</span>
            </li>
          ))}
          {row.fileCount > row.files.length && (
            <li className="rvnote">{t('workflow.add.moreFiles', { count: row.fileCount - row.files.length })}</li>
          )}
          <li className="rvnote">{t('workflow.add.filesHint')}</li>
        </ul>
      )}
    </li>
  )
}

const STATUS_BADGE: Record<ReviewRow['status'], 'ok' | 'warn' | 'bad'> = {
  ok: 'ok',
  unchecked: 'ok',
  duplicate: 'warn',
  unsupported: 'bad',
  refused: 'bad',
  credentials: 'bad',
}
