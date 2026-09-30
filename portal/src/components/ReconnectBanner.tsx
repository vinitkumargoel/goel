import { useTranslation } from 'react-i18next'
import { fmtClock } from '../lib/format'
import { RetryIcon } from './Icons'

/** How long the stream may be down before the banner interrupts; brief blips stay in the status bar. */
export const STALE_AFTER_MS = 5000

/** True once the stream is down and the newest data is older than `STALE_AFTER_MS`. */
export function isStale(live: boolean, lastUpdate: number | null, now: number): boolean {
  return !live && lastUpdate != null && now - lastUpdate > STALE_AFTER_MS
}

interface ReconnectBannerProps {
  /** Whether to show it — see `isStale`. The live region stays mounted either way. */
  stale: boolean
  lastUpdate: number | null
  now: number
  onRetry: () => void
}

/**
 * The strip under the topbar while the data is stale. The polite live region is always in the DOM
 * (an announcement into a freshly inserted region is often dropped); only its content comes and goes.
 */
export function ReconnectBanner({ stale, lastUpdate, now, onRetry }: ReconnectBannerProps) {
  const { t } = useTranslation()
  const show = stale && lastUpdate != null
  const age = show ? fmtClock((now - lastUpdate) / 1000) : ''

  // The ticking age is hidden from the live region: re-announcing it every second would drown a
  // screen reader. The region says it once; the visible clock is for sighted users.
  return (
    <div className={`reconnect${show ? ' show' : ''}`}>
      <span className="sr-only" role="status" aria-live="polite">
        {show ? t('reconnect.announce') : ''}
      </span>
      {show && (
        <>
          <span className="rc-text" aria-hidden="true">
            {t('reconnect.lost', { age })} · <span className="rc-dim">{t('reconnect.retrying')}</span>
          </span>
          <button type="button" className="rc-btn" onClick={onRetry}>
            <RetryIcon aria-hidden="true" />
            {t('reconnect.retryNow')}
          </button>
        </>
      )}
    </div>
  )
}
