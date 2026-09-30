import { useTranslation } from 'react-i18next'
import type { BandwidthState } from '../lib/bandwidth'
import { fmtSpeed, IDLE_RATE } from '../lib/format'
import { BandwidthPill } from './BandwidthPill'
import { ArrowDownIcon, ArrowUpIcon, PauseIcon, PlayIcon } from './Icons'

interface StatusBarProps {
  live: boolean
  loaded: boolean
  active: number
  downSpeed: number
  upSpeed: number
  readOnly: boolean
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
  active,
  downSpeed,
  upSpeed,
  readOnly,
  onPauseAll,
  onResumeAll,
  bandwidth = null,
  bandwidthMenuOpen = false,
  onBandwidthMenu,
}: StatusBarProps) {
  const { t } = useTranslation()
  const conn = live ? 'live' : loaded ? 'reconnecting' : 'connecting'

  return (
    <footer className="statusbar">
      <span className={`conn conn-${conn}`} role="status">
        <span className="cdot" aria-hidden="true" />
        <span className="ctext">{t(`statusbar.${conn}`)}</span>
      </span>
      <span className="sb-dim sb-active">{t('statusbar.active', { count: active })}</span>
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
          menuOpen={bandwidthMenuOpen}
          onOpen={onBandwidthMenu}
        />
      )}
      <span className="stat down">
        <ArrowDownIcon aria-hidden="true" />
        <span className="sr-only">{t('statusbar.downSpeed')}</span>
        <b>{fmtSpeed(downSpeed, IDLE_RATE)}</b>
      </span>
      <span className="stat up">
        <ArrowUpIcon aria-hidden="true" />
        <span className="sr-only">{t('statusbar.upSpeed')}</span>
        <b>{fmtSpeed(upSpeed, IDLE_RATE)}</b>
      </span>
      {readOnly && <span className="chip chip-ro">{t('statusbar.readOnly')}</span>}
    </footer>
  )
}
