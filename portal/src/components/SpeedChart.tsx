import { useTranslation } from 'react-i18next'
import { fmtSpeed } from '../lib/format'
import { HISTORY_LENGTH, peakRate, seriesPath, type SpeedSample } from '../lib/speedHistory'

const W = 300
const H = 120
/** Headroom above the peak so the line never kisses the top edge. */
const HEADROOM = 1.15

interface SpeedChartProps {
  samples: readonly SpeedSample[]
}

/**
 * The last minute of one download: ↓ as a filled accent area, ↑ as a teal line. Scales to the
 * panel's width (the viewBox stretches horizontally; strokes keep their width).
 */
export function SpeedChart({ samples }: SpeedChartProps) {
  const { t } = useTranslation()
  const peak = peakRate(samples)
  const scale = peak * HEADROOM
  const down = samples.map((s) => s.down)
  const up = samples.map((s) => s.up)
  const downPeak = Math.max(0, ...down)
  const upPeak = Math.max(0, ...up)

  return (
    <figure className="schart">
      <div className="schart-top">
        <span className="schart-legend">
          <i className="lg-down" aria-hidden="true" /> {t('chart.down')}
          <i className="lg-up" aria-hidden="true" /> {t('chart.up')}
        </span>
        <span className="schart-peak">{t('chart.peak', { rate: fmtSpeed(peak, '0 B/s') })}</span>
      </div>
      <svg
        viewBox={`0 0 ${W} ${H}`}
        preserveAspectRatio="none"
        role="img"
        aria-label={t('chart.label', {
          down: fmtSpeed(downPeak, '0 B/s'),
          up: fmtSpeed(upPeak, '0 B/s'),
        })}
      >
        <line className="schart-grid" x1="0" x2={W} y1={H / 2} y2={H / 2} />
        <path className="schart-area" d={seriesPath(down, W, H, scale, true, HISTORY_LENGTH)} />
        <path className="schart-down" d={seriesPath(down, W, H, scale, false, HISTORY_LENGTH)} />
        <path className="schart-up" d={seriesPath(up, W, H, scale, false, HISTORY_LENGTH)} />
      </svg>
      <figcaption className="schart-axis" aria-hidden="true">
        <span>{t('chart.ago')}</span>
        <span>{t('chart.now')}</span>
      </figcaption>
    </figure>
  )
}

interface SparklineProps {
  samples: readonly SpeedSample[]
  label: string
}

/** The topbar's tiny total-download trend. Decorative next to the figures, but still named. */
export function Sparkline({ samples, label }: SparklineProps) {
  const w = 60
  const h = 18
  const down = samples.map((s) => s.down)
  const peak = Math.max(0, ...down) * HEADROOM
  return (
    <svg className="spark" viewBox={`0 0 ${w} ${h}`} preserveAspectRatio="none" role="img" aria-label={label}>
      <path className="spark-area" d={seriesPath(down, w, h, peak, true)} />
      <path className="spark-line" d={seriesPath(down, w, h, peak, false)} />
    </svg>
  )
}
