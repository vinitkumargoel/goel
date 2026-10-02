import { useMemo } from 'react'
import { useTranslation } from 'react-i18next'
import { fmtSize } from '../../lib/format'
import type { HistoryRow } from '../../lib/types'
import { Art } from '../ui/Art'
import { monthSummary } from './historyParts'

/** The side card on a wide screen: this month's total, its count, and the bytes by file type. */
export function HistorySummary({ rows, titleId }: { rows: readonly HistoryRow[]; titleId: string }) {
  const { t } = useTranslation()
  const month = useMemo(() => monthSummary(rows), [rows])
  const allBytes = useMemo(() => rows.reduce((n, r) => n + (r.totalBytes ?? 0), 0), [rows])
  return (
    <aside className="card pad hist-side" aria-labelledby={titleId}>
      <h2 className="eyebrow" id={titleId}>
        {t('pages.history.thisMonth')}
      </h2>
      <span className="hist-big">{fmtSize(month.bytes)}</span>
      <span className="small muted">{t('pages.history.finished', { count: month.count })}</span>
      {month.byType.length > 0 && (
        <ul className="hist-types" aria-label={t('pages.history.byType')}>
          {month.byType.map((x) => (
            <li key={x.type} className="row small">
              <Art kind={x.type} size="xs" />
              <span className="sp">{t(`fileType.${x.type}` as 'fileType.other')}</span>
              <span className="mono muted">{fmtSize(x.bytes)}</span>
            </li>
          ))}
        </ul>
      )}
      <hr className="sep" />
      <span className="tiny muted">
        {t('pages.history.allTime', { count: rows.length, size: fmtSize(allBytes) })}
      </span>
    </aside>
  )
}
