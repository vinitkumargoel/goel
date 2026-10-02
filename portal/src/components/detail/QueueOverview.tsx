import { useId } from 'react'
import { useTranslation } from 'react-i18next'
import { capSummary, type BandwidthState } from '../../lib/bandwidth'
import type { Filter, FilterCounts } from '../../lib/filters'
import { fmtSize, fmtSpeed, IDLE_RATE, pct } from '../../lib/format'
import { fmtFinishAt, queueEstimate } from '../../lib/queue'
import { useSpeedSeries } from '../../lib/speedStore'
import type { StatusToken, TaskRow } from '../../lib/types'
import { ToggleRow } from '../ui/Controls'
import { Ring } from '../ui/Meter'
import { SpeedChart } from '../ui/SpeedChart'

const TILES = ['active', 'queued', 'completed', 'failed'] as const

/** What the Remaining arc measures: the same pending set `queueEstimate` counts. */
const PENDING: ReadonlySet<StatusToken> = new Set<StatusToken>(['downloading', 'verifying', 'metadata', 'queued'])

interface QueueOverviewProps {
  tasks: readonly TaskRow[]
  counts: FilterCounts
  down: number
  up: number
  bandwidth: BandwidthState | null
  autoHide: boolean
  onAutoHide: (on: boolean) => void
  onFilter: (filter: Filter) => void
}

/** Done over total across pending downloads of known size; null when there is nothing to measure. */
export function queueFraction(tasks: readonly TaskRow[]): number | null {
  let done = 0
  let total = 0
  for (const task of tasks) {
    if (!PENDING.has(task.statusToken) || task.totalBytes == null || task.totalBytes <= 0) continue
    total += task.totalBytes
    done += Math.min(task.doneBytes, task.totalBytes)
  }
  return total > 0 ? done / total : null
}

/**
 * What the sheet shows with nothing selected: how fast, how much is left, when it will be done,
 * and whether anything needs attention — each count a shortcut to its filter.
 */
export function QueueOverview({
  tasks,
  counts,
  down,
  up,
  bandwidth,
  autoHide,
  onAutoHide,
  onFilter,
}: QueueOverviewProps) {
  const { t } = useTranslation()
  const id = useId()
  const est = queueEstimate(tasks)
  const fraction = queueFraction(tasks)
  const profile = bandwidth?.profiles.find((p) => p.name === bandwidth.selected)
  const nothingLeft = est.remainingBytes === 0

  return (
    <section className="qov" aria-labelledby={`${id}-h`}>
      <div className="qov-h">
        <h2 className="h2" id={`${id}-h`}>
          {t('overview.title')}
        </h2>
        <span className="sp" />
        <span className="mono small qov-rates">
          <span className="sr-only">
            {t('sheet.rates', { down: fmtSpeed(down, IDLE_RATE), up: fmtSpeed(up, IDLE_RATE) })}
          </span>
          <span className="acc" aria-hidden="true">
            ↓ {fmtSpeed(down, IDLE_RATE)}
          </span>{' '}
          <span className="upc" aria-hidden="true">
            ↑ {fmtSpeed(up, IDLE_RATE)}
          </span>
        </span>
      </div>

      <div className="qov-tiles" role="group" aria-label={t('overview.tilesLabel')}>
        {TILES.map((key) => {
          const flagged = key === 'failed' && counts.failed > 0
          return (
            <button
              key={key}
              type="button"
              className={`stat qov-tile ${key}${flagged ? ' bad' : ''}`}
              onClick={() => onFilter(key)}
              aria-label={t(`overview.show.${key}`, { count: counts[key] })}
            >
              <b>{counts[key]}</b>
              <span>
                {t(`sheet.overview.tile.${key}`)}
                {flagged && ` · ${t('sheet.overview.failedHint')}`}
              </span>
            </button>
          )
        })}
      </div>

      <div className="hero qov-hero">
        <div className="qov-left">
          <span className="eyebrow">{t('overview.remaining')}</span>
          {nothingLeft ? (
            <span className="h3">{t('overview.nothingLeft')}</span>
          ) : (
            <>
              <span className="disp qov-size">{fmtSize(est.remainingBytes)}</span>
              <span className="small muted">
                {est.seconds != null
                  ? t('overview.doneAt', { time: fmtFinishAt(est.seconds) })
                  : t('overview.stalled')}
              </span>
            </>
          )}
        </div>
        {fraction != null && (
          <Ring
            value={fraction}
            size={70}
            tone={est.seconds == null ? 'paused' : ''}
            label={t('sheet.overview.ring', { percent: Math.floor(pct(fraction)) })}
          >
            <b>{Math.floor(pct(fraction))}%</b>
          </Ring>
        )}
      </div>
      {est.unknown > 0 && <p className="small muted qov-unknown">{t('overview.unknownSize', { count: est.unknown })}</p>}

      <TotalChart />

      {bandwidth && (
        <dl className="facts">
          <dt>{t('overview.bandwidth')}</dt>
          <dd>
            {bandwidth.enabled && profile
              ? `${profile.name} · ${capSummary(profile, t('settings.bandwidth.noCap'))}`
              : t('statusbar.unlimited')}
          </dd>
        </dl>
      )}

      <ToggleRow id={`${id}-auto`} title={t('overview.autoHide')} checked={autoHide} onChange={onAutoHide} />
    </section>
  )
}

/** The whole queue's last minute. Subscribes on its own, so a sample redraws only the chart. */
function TotalChart() {
  const { t } = useTranslation()
  const samples = useSpeedSeries('total')
  const peak = samples.reduce((m, s) => Math.max(m, s.down), 0)
  return (
    <div className="sect">
      <div className="sect-h">
        <span className="eyebrow">{t('sheet.overview.chart')}</span>
        <span className="sp" />
        <span className="mono tiny faint">{t('chart.peak', { rate: fmtSpeed(peak, IDLE_RATE) })}</span>
      </div>
      <SpeedChart samples={samples} height={70} showUp={false} />
    </div>
  )
}
