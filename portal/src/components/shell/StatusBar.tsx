import { useTranslation } from 'react-i18next'
import type { BandwidthState } from '../../lib/bandwidth'
import type { Filter } from '../../lib/filters'
import { fmtSize, fmtSpeed, IDLE_RATE } from '../../lib/format'
import { fmtFinishAt, type QueueEstimate } from '../../lib/queue'
import { peakRate } from '../../lib/speedHistory'
import { useSpeedSeries } from '../../lib/speedStore'
import { Icon } from '../ui/Icon'
import { Popover } from '../ui/Popover'
import { SpeedChart } from '../ui/SpeedChart'
import { BandwidthPill } from './BandwidthPill'

export type QueueCounts = Record<'active' | 'queued' | 'paused' | 'seeding' | 'failed', number>

/** Active always shows, so the summary never reads empty; the rest only when there is something to say. */
const QUEUE_KEYS = ['active', 'queued', 'paused', 'seeding', 'failed'] as const

interface StatusBarProps {
  queue: QueueCounts
  downSpeed: number
  upSpeed: number
  estimate: QueueEstimate
  readOnly: boolean
  /** Makes each count a shortcut to that filter. */
  onFilter?: (filter: Filter) => void
  onPauseAll?: () => void
  onResumeAll?: () => void
  /** Null hides the pill: not loaded yet, or a daemon without the feature. */
  bandwidth?: BandwidthState | null
  bandwidthMenuOpen?: boolean
  onBandwidthMenu?: (anchor: DOMRect) => void
}

function SpeedPopover() {
  const { t } = useTranslation()
  const samples = useSpeedSeries('total')
  const now = samples.length > 0 ? samples[samples.length - 1]! : { down: 0, up: 0 }
  return (
    <Popover
      label={t('shell.status.chart')}
      triggerClassName="ibtn sm"
      trigger={<Icon name="chart" size="s" />}
      above
      alignEnd
      className="speed-pop"
    >
      <div className="row">
        <span className="h3">{t('shell.status.chartTitle')}</span>
        <span className="sp" />
        <span className="mono tiny faint">
          {t('shell.status.peakNow', { peak: fmtSpeed(peakRate(samples), IDLE_RATE), now: fmtSpeed(now.down, IDLE_RATE) })}
        </span>
      </div>
      {samples.length > 1 ? (
        <SpeedChart samples={samples} height={110} />
      ) : (
        <p className="small muted">{t('shell.status.idle')}</p>
      )}
      <div className="row mono tiny faint">
        <span>{t('chart.ago')}</span>
        <span className="sp" />
        <span>
          <span className="lg acc">{t('chart.down')}</span> <span className="lg up">{t('chart.up')}</span>
        </span>
      </div>
    </Popover>
  )
}

/**
 * The bottom bar: live totals and when the queue should be done, the count of each state (each a
 * shortcut to its filter), pause/resume everything, the speed graph and the bandwidth profile.
 */
export function StatusBar({
  queue,
  downSpeed,
  upSpeed,
  estimate,
  readOnly,
  onFilter,
  onPauseAll,
  onResumeAll,
  bandwidth = null,
  bandwidthMenuOpen = false,
  onBandwidthMenu,
}: StatusBarProps) {
  const { t } = useTranslation()
  const shown = QUEUE_KEYS.filter((key) => key === 'active' || queue[key] > 0)
  const left =
    estimate.remainingBytes > 0
      ? [
          t('shell.status.left', { size: fmtSize(estimate.remainingBytes) }),
          estimate.seconds != null ? t('shell.status.doneAt', { time: fmtFinishAt(estimate.seconds) }) : null,
          // The estimate leaves out what has no size yet; say so rather than promise too early a finish.
          estimate.unknown > 0 ? t('shell.status.unknown', { count: estimate.unknown }) : null,
        ]
          .filter(Boolean)
          .join(' · ')
      : null

  return (
    <footer className="sbar">
      <span className="mono sb-rates">
        <span className="acc">
          <span className="sr-only">{t('statusbar.downSpeed')} </span>↓ {fmtSpeed(downSpeed, IDLE_RATE)}
        </span>
        <span className="upc">↑ {fmtSpeed(upSpeed, IDLE_RATE)}</span>
      </span>
      {left && (
        <>
          <span className="faint sb-dot" aria-hidden="true">
            ·
          </span>
          <span className="sb-left">{left}</span>
        </>
      )}
      <span className="faint sb-dot" aria-hidden="true">
        ·
      </span>
      <span className="sb-counts" role="group" aria-label={t('shell.status.counts')}>
        {shown.map((key) => {
          const label = t(`statusbar.${key}`, { count: queue[key] })
          const cls = `chip sm${key === 'failed' ? ' bad' : ''}`
          return onFilter ? (
            <button key={key} type="button" className={cls} onClick={() => onFilter(key)} title={t('statusbar.showFilter')}>
              {label}
            </button>
          ) : (
            <span key={key} className={cls}>
              {label}
            </span>
          )
        })}
      </span>
      <span className="sp" />
      {/* Cosmetic only — the server, not this flag, refuses a read-only session's POST. */}
      {!readOnly && onPauseAll && onResumeAll && (
        <span className="seg sm" role="group" aria-label={t('statusbar.allControls')}>
          <button type="button" onClick={onPauseAll} title={t('statusbar.pauseAll')}>
            <Icon name="pause" size="s" />
            <span className="sr-only">{t('statusbar.pauseAll')}</span>
            <span aria-hidden="true">{t('statusbar.all')}</span>
          </button>
          <button type="button" onClick={onResumeAll} title={t('statusbar.resumeAll')}>
            <Icon name="play" size="s" />
            <span className="sr-only">{t('statusbar.resumeAll')}</span>
            <span aria-hidden="true">{t('statusbar.all')}</span>
          </button>
        </span>
      )}
      <SpeedPopover />
      {bandwidth && onBandwidthMenu && (
        <BandwidthPill state={bandwidth} canWrite={!readOnly} menuOpen={bandwidthMenuOpen} onOpen={onBandwidthMenu} />
      )}
      {readOnly && <span className="pill warn nodot">{t('statusbar.readOnly')}</span>}
    </footer>
  )
}
