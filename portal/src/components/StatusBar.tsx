import { Fragment } from 'react'
import { useTranslation } from 'react-i18next'
import { useMediaQuery } from '../hooks/useMediaQuery'
import type { BandwidthState } from '../lib/bandwidth'
import type { Filter } from '../lib/filters'
import { fmtSpeed, IDLE_RATE } from '../lib/format'
import { BandwidthPill } from './BandwidthPill'
import { ArrowDownIcon, PauseIcon, PlayIcon } from './Icons'

export type QueueCounts = Record<'active' | 'queued' | 'paused' | 'seeding' | 'failed', number>

/** Active always shows, so the summary never reads empty; the rest only when there is something to say. */
const QUEUE_KEYS = ['active', 'queued', 'paused', 'seeding', 'failed'] as const

interface StatusBarProps {
  live: boolean
  loaded: boolean
  queue: QueueCounts
  /** Only drawn ≤680px, where the topbar hides its rates; upload has no room there (the overview has it). */
  downSpeed: number
  readOnly: boolean
  /** Makes each summary figure a shortcut to that sidebar filter. */
  onFilter?: (filter: Filter) => void
  onPauseAll?: () => void
  onResumeAll?: () => void
  /** Null hides the pill: not loaded yet, or a daemon without the feature. */
  bandwidth?: BandwidthState | null
  bandwidthMenuOpen?: boolean
  onBandwidthMenu?: (anchor: DOMRect) => void
}

/** Connection first: when the event stream drops, the list behind it is going stale. */
export function StatusBar({
  live,
  loaded,
  queue,
  downSpeed,
  readOnly,
  onFilter,
  onPauseAll,
  onResumeAll,
  bandwidth = null,
  bandwidthMenuOpen = false,
  onBandwidthMenu,
}: StatusBarProps) {
  const { t } = useTranslation()
  const phone = useMediaQuery('(max-width: 680px)')
  const conn = live ? 'live' : loaded ? 'reconnecting' : 'connecting'
  const shown = QUEUE_KEYS.filter((key) => key === 'active' || queue[key] > 0)

  return (
    <footer className="statusbar">
      <span className={`conn conn-${conn}`} role="status">
        <span className="cdot" aria-hidden="true" />
        <span className="ctext">{t(`statusbar.${conn}`)}</span>
      </span>
      <span className="sb-queue">
        {shown.map((key, i) => {
          const label = t(`statusbar.${key}`, { count: queue[key] })
          const cls = `sbq${key === 'failed' ? ' bad' : ''}`
          return (
            <Fragment key={key}>
              {i > 0 && (
                <span className="sbq-sep" aria-hidden="true">
                  ·
                </span>
              )}
              {onFilter ? (
                <button type="button" className={cls} onClick={() => onFilter(key)} title={t('statusbar.showFilter')}>
                  {label}
                </button>
              ) : (
                <span className={cls}>{label}</span>
              )}
            </Fragment>
          )
        })}
      </span>
      <div className="sp" />
      {/* Cosmetic only — the server, not this flag, refuses a read-only session's POST. */}
      {!readOnly && onPauseAll && onResumeAll && (
        <div className="sb-seg" role="group" aria-label={t('statusbar.allControls')}>
          <button type="button" onClick={onPauseAll} title={t('statusbar.pauseAll')}>
            <PauseIcon aria-hidden="true" />
            <span className="sr-only">{t('statusbar.pauseAll')}</span>
            <span aria-hidden="true">{t('statusbar.all')}</span>
          </button>
          <button type="button" onClick={onResumeAll} title={t('statusbar.resumeAll')}>
            <PlayIcon aria-hidden="true" />
            <span className="sr-only">{t('statusbar.resumeAll')}</span>
            <span aria-hidden="true">{t('statusbar.all')}</span>
          </button>
        </div>
      )}
      {bandwidth && onBandwidthMenu && (
        <BandwidthPill
          state={bandwidth}
          canWrite={!readOnly}
          compact={phone}
          menuOpen={bandwidthMenuOpen}
          onOpen={onBandwidthMenu}
        />
      )}
      {phone && (
        <span className="stat down">
          <ArrowDownIcon aria-hidden="true" />
          <span className="sr-only">{t('statusbar.downSpeed')}</span>
          <b>{fmtSpeed(downSpeed, IDLE_RATE)}</b>
        </span>
      )}
      {readOnly && <span className="chip chip-ro">{t('statusbar.readOnly')}</span>}
    </footer>
  )
}
