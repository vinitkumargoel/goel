import { useTranslation } from 'react-i18next'
import { fmtRate } from '../lib/format'
import { ArrowDownIcon, ArrowUpIcon } from './Icons'

interface StatusBarProps {
  live: boolean
  loaded: boolean
  active: number
  downSpeed: number
  upSpeed: number
  readOnly: boolean
}

/** Connection first: when the event stream drops, the list behind it is going stale. */
export function StatusBar({ live, loaded, active, downSpeed, upSpeed, readOnly }: StatusBarProps) {
  const { t } = useTranslation()
  const conn = live ? 'live' : loaded ? 'reconnecting' : 'connecting'

  return (
    <footer className="statusbar">
      <span className={`conn conn-${conn}`} role="status">
        <span className="cdot" aria-hidden="true" />
        <span className="ctext">{t(`statusbar.${conn}`)}</span>
      </span>
      <span className="sb-dim">{t('statusbar.active', { count: active })}</span>
      <div className="sp" />
      <span className="stat down">
        <ArrowDownIcon aria-hidden="true" />
        <span className="sr-only">{t('statusbar.downSpeed')}</span>
        <b>{fmtRate(downSpeed)}</b>
      </span>
      <span className="stat up">
        <ArrowUpIcon aria-hidden="true" />
        <span className="sr-only">{t('statusbar.upSpeed')}</span>
        <b>{fmtRate(upSpeed)}</b>
      </span>
      {readOnly && <span className="chip chip-ro">{t('statusbar.readOnly')}</span>}
    </footer>
  )
}
