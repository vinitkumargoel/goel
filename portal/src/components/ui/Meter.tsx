import type { CSSProperties, ReactNode } from 'react'

type MeterTone = '' | 'paused' | 'up' | 'good' | 'bad' | 'warn'

interface RingProps {
  /** 0…1; null spins (no total yet, fetching metadata). */
  value: number | null
  /** Diameter in px. */
  size?: number
  tone?: MeterTone
  /** Drawn in the middle: the percentage, an icon. */
  children?: ReactNode
  /** Sweep in from zero on mount (the board's arcs); off for arcs that update in place. */
  sweep?: boolean
  className?: string
  /** Names the arc for assistive tech; without one it is decorative. */
  label?: string
}

/** The Studio progress arc (`.rw` + `.ring`). */
export function Ring({ value, size = 46, tone = '', children, sweep = false, className, label }: RingProps) {
  const spin = value == null
  const p = spin ? 0 : Math.round(Math.max(0, Math.min(1, value)) * 1000) / 10
  const ringCls = ['ring', tone, spin ? 'spin' : '', sweep ? 'sweep' : ''].filter(Boolean).join(' ')
  const a11y = label
    ? spin
      ? { role: 'progressbar', 'aria-label': label }
      : { role: 'progressbar', 'aria-label': label, 'aria-valuemin': 0, 'aria-valuemax': 100, 'aria-valuenow': Math.round(p) }
    : { 'aria-hidden': true }
  return (
    <span className={`rw${className ? ` ${className}` : ''}`} {...a11y}>
      <svg className={ringCls} viewBox="0 0 40 40" width={size} height={size} style={{ width: size, height: size }}>
        <circle className="t" cx="20" cy="20" r="16" />
        <circle className="v" cx="20" cy="20" r="16" pathLength={100} style={{ '--p': p } as CSSProperties} />
      </svg>
      {children}
    </span>
  )
}

interface BarProps {
  /** 0…1; null is indeterminate. */
  value: number | null
  tone?: MeterTone
  thin?: boolean
  className?: string
  /** Names the bar for assistive tech; without one it is decorative. */
  label?: string
}

/** The Studio progress bar (`.bar`). */
export function Bar({ value, tone = '', thin = false, className, label }: BarProps) {
  const ind = value == null
  const p = ind ? 0 : Math.max(0, Math.min(1, value)) * 100
  const cls = ['bar', thin ? 'thin' : '', tone, ind ? 'ind' : '', className ?? ''].filter(Boolean).join(' ')
  const a11y = label
    ? ind
      ? { role: 'progressbar', 'aria-label': label }
      : { role: 'progressbar', 'aria-label': label, 'aria-valuemin': 0, 'aria-valuemax': 100, 'aria-valuenow': Math.round(p) }
    : { 'aria-hidden': true }
  return (
    <span className={cls} {...a11y}>
      <i style={ind ? undefined : ({ '--p': `${p}%` } as CSSProperties)} />
    </span>
  )
}
