import type { CSSProperties } from 'react'
import { useTranslation } from 'react-i18next'
import { fmtSpeed } from '../../lib/format'
import { HISTORY_LENGTH, peakRate, seriesPath, type SpeedSample } from '../../lib/speedHistory'
import { useSpeedSeries } from '../../lib/speedStore'

/** Headroom above the peak so the line never kisses the top edge. */
const HEADROOM = 1.15
const W = 300

interface SpeedChartProps {
  samples: readonly SpeedSample[]
  /** Drawn height in px; the chart stretches to its container's width. */
  height?: number
  /** Horizontal guide lines. */
  grid?: number
  /** ↑ as a dashed second line. */
  showUp?: boolean
  /** A dot on the newest ↓ sample. */
  endDot?: boolean
  /** Overrides the computed accessible name. */
  label?: string
  className?: string
}

/**
 * The Studio area chart (`.spark`): ↓ as a filled accent area, ↑ as a dashed line, newest sample
 * at the right edge. Its accessible name states both peaks.
 */
export function SpeedChart({
  samples,
  height = 60,
  grid = 2,
  showUp = true,
  endDot = true,
  label,
  className,
}: SpeedChartProps) {
  const { t } = useTranslation()
  const H = height
  const scale = peakRate(samples) * HEADROOM
  const down = samples.map((s) => s.down)
  const up = samples.map((s) => s.up)
  const name =
    label ??
    t('chart.label', {
      down: fmtSpeed(Math.max(0, ...down), '0 B/s'),
      up: fmtSpeed(Math.max(0, ...up), '0 B/s'),
    })
  const last = down.length > 0 ? down[down.length - 1]! : 0
  const lastY = scale > 0 ? H - Math.min(last, scale) * (H / scale) : H
  return (
    <span className={`chart${className ? ` ${className}` : ''}`}>
      <svg
        className="spark"
        viewBox={`0 0 ${W} ${H}`}
        preserveAspectRatio="none"
        style={{ height: H }}
        role="img"
        aria-label={name}
      >
        {Array.from({ length: grid }, (_, i) => {
          const y = Math.round(((i + 1) * H) / (grid + 1))
          return <line key={i} className="g" x1="0" x2={W} y1={y} y2={y} />
        })}
        <path className="a" d={seriesPath(down, W, H, scale, true, HISTORY_LENGTH)} />
        <path className="l" d={seriesPath(down, W, H, scale, false, HISTORY_LENGTH)} />
        {showUp && <path className="l2" d={seriesPath(up, W, H, scale, false, HISTORY_LENGTH)} />}
      </svg>
      {endDot && down.length > 1 && (
        // An element, not an SVG circle: the stretched viewBox would draw a circle as an ellipse.
        <i className="chart-dot" aria-hidden="true" style={{ top: `${(lastY / H) * 100}%` } as CSSProperties} />
      )}
    </span>
  )
}

/** The whole queue's last minute, subscribed on its own so a sample redraws only the chart. */
export function TotalSpeedChart(props: Omit<SpeedChartProps, 'samples'>) {
  const samples = useSpeedSeries('total')
  return samples.length > 1 ? <SpeedChart samples={samples} {...props} /> : null
}
