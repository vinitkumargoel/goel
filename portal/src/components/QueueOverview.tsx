import { useId } from 'react'
import { useTranslation } from 'react-i18next'
import { capSummary, type BandwidthState } from '../lib/bandwidth'
import type { Filter, FilterCounts } from '../lib/filters'
import { fmtSize, fmtSpeed, IDLE_RATE } from '../lib/format'
import { fmtFinishAt, queueEstimate } from '../lib/queue'
import { useSpeedSeries } from '../lib/speedStore'
import type { TaskRow } from '../lib/types'
import { SpeedChart } from './SpeedChart'

const TILES = ['active', 'queued', 'completed', 'failed'] as const

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

/** The whole queue's last minute. Subscribes on its own, so a sample redraws only the chart. */
function TotalChart() {
  return <SpeedChart samples={useSpeedSeries('total')} compact />
}

/**
 * What the detail panel shows with nothing selected: the space that used to say "No download
 * selected" answers the questions the queue as a whole raises — how fast, how much is left, when
 * it will be done, and whether anything needs attention.
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
  const profile = bandwidth?.profiles.find((p) => p.name === bandwidth.selected)

  const remaining =
    est.remainingBytes === 0
      ? t('overview.nothingLeft')
      : [
          fmtSize(est.remainingBytes),
          est.seconds != null
            ? t('overview.doneAt', { time: fmtFinishAt(est.seconds) })
            : t('overview.stalled'),
        ].join(' · ')

  return (
    <section className="qov" aria-labelledby={`${id}-h`}>
      <h2 className="qov-h" id={`${id}-h`}>
        {t('overview.title')}
      </h2>

      <div className="drates">
        <div className="drate down">
          <span className="drk">{t('chart.down')}</span>
          <b>{fmtSpeed(down, IDLE_RATE)}</b>
        </div>
        <div className="drate up">
          <span className="drk">{t('chart.up')}</span>
          <b>{fmtSpeed(up, IDLE_RATE)}</b>
        </div>
      </div>
      <TotalChart />

      <div className="qtiles" role="group" aria-label={t('overview.tilesLabel')}>
        {TILES.map((key) => (
          <button
            key={key}
            type="button"
            className={`qtile${key === 'failed' && counts.failed > 0 ? ' bad' : ''}`}
            onClick={() => onFilter(key)}
            aria-label={t(`overview.show.${key}`, { count: counts[key] })}
          >
            <b>{counts[key]}</b>
            <span>{t(`overview.tile.${key}`)}</span>
          </button>
        ))}
      </div>

      <div className="kv">
        <span className="k">{t('overview.remaining')}</span>
        <span className="v">{remaining}</span>
      </div>
      {est.unknown > 0 && (
        <p className="fhint" style={{ marginTop: 0 }}>
          {t('overview.unknownSize', { count: est.unknown })}
        </p>
      )}
      {bandwidth && (
        <div className="kv">
          <span className="k">{t('overview.bandwidth')}</span>
          <span className="v">
            {bandwidth.enabled && profile
              ? `${profile.name} · ${capSummary(profile, t('settings.bandwidth.noCap'))}`
              : t('statusbar.unlimited')}
          </span>
        </div>
      )}

      <label className="qov-auto">
        <input type="checkbox" checked={autoHide} onChange={(e) => onAutoHide(e.target.checked)} />
        {t('overview.autoHide')}
      </label>
    </section>
  )
}
