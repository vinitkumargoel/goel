import { useTranslation } from 'react-i18next'
import { streamURL } from '../../lib/api'
import { meterClass, stateTone } from '../../lib/tone'
import type { StatusToken, TaskRow } from '../../lib/types'
import { Icon, type IconName } from '../ui/Icon'

/** Moving now, so live rates and the chart mean something; a finished or failed task shows neither. */
const LIVE: ReadonlySet<StatusToken> = new Set<StatusToken>(['downloading', 'seeding', 'verifying', 'metadata'])

export function isLive(row: Pick<TaskRow, 'statusToken'>): boolean {
  return LIVE.has(row.statusToken)
}

/** ↑ only means something for a torrent, or for anything actually sending. */
export function showsUpload(row: Pick<TaskRow, 'kind' | 'upSpeed'>): boolean {
  return row.kind === 'torrent' || row.upSpeed > 0
}

/** A ring or bar modifier for the download's state ('' = the accent). */
export type MeterTone = '' | 'paused' | 'up' | 'good' | 'bad'

export function meterTone(row: Pick<TaskRow, 'statusToken'>): MeterTone {
  // meterClass only ever answers one of these.
  return meterClass(stateTone(row)) as MeterTone
}

/** The glyph in the middle of a download's arc. */
export function stateGlyph(status: StatusToken): IconName {
  switch (status) {
    case 'downloading':
    case 'metadata':
      return 'down'
    case 'verifying':
      return 'shield'
    case 'queued':
      return 'clock'
    case 'paused':
      return 'pause'
    case 'failed':
      return 'alert'
    case 'seeding':
      return 'up'
    case 'completed':
      return 'check'
  }
}

/** The in-page player when the app offers one, else the stream in a new tab. */
export function openStream(row: TaskRow, onStream?: (row: TaskRow) => void): void {
  if (onStream) onStream(row)
  else window.open(streamURL(row.id), '_blank', 'noopener,noreferrer')
}

/** Where a menu opened from `el` should sit: its left edge, just above it. */
export function anchorAbove(el: Element): { x: number; y: number } {
  const r = el.getBoundingClientRect()
  return { x: r.left, y: r.top - 6 }
}

/** A value that is worth copying (a path, a link): the text truncates, the button copies it whole. */
export function CopyValue({ value, onCopy, mono = true }: { value: string; onCopy: (text: string) => void; mono?: boolean }) {
  const { t } = useTranslation()
  return (
    <>
      <span className={`ell${mono ? ' mono' : ''}`} title={value}>
        {value}
      </span>
      <button type="button" className="ibtn sm dcopy-btn" onClick={() => onCopy(value)} aria-label={t('common.copy')} title={t('common.copy')}>
        <Icon name="copy" size="s" />
      </button>
    </>
  )
}
