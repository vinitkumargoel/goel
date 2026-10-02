import { useTranslation } from 'react-i18next'
import { fmtClock } from '../../lib/format'
import { Icon } from '../ui/Icon'

/** How long the stream may be down before the banner interrupts; brief blips stay in the header. */
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
 * The note under the header while the data is stale. The polite live region is always in the DOM
 * (an announcement into a freshly inserted region is often dropped); only its content comes and goes.
 */
export function ReconnectBanner({ stale, lastUpdate, now, onRetry }: ReconnectBannerProps) {
  const { t } = useTranslation()
  const show = stale && lastUpdate != null
  const age = show ? fmtClock((now - lastUpdate) / 1000) : ''

  // The ticking age is hidden from the live region: re-announcing it every second would drown a
  // screen reader. The region says it once; the visible clock is for sighted users.
  return (
    <div className="banner-slot">
      <span className="sr-only" role="status" aria-live="polite">
        {show ? t('reconnect.announce') : ''}
      </span>
      {show && (
        <div className="note warn banner reconnect">
          <Icon name="wifiOff" />
          <span className="banner-t" aria-hidden="true">
            {t('reconnect.lost', { age })} · <span className="muted">{t('reconnect.retrying')}</span>
          </span>
          <button type="button" className="btn sm" onClick={onRetry}>
            <Icon name="retry" />
            {t('reconnect.retryNow')}
          </button>
        </div>
      )}
    </div>
  )
}

/** Shown on every view of a read-only session; the server is what actually refuses the writes. */
export function ReadOnlyBanner() {
  const { t } = useTranslation()
  return (
    <div className="banner-slot">
      <div className="note banner readonly">
        <Icon name="eye" />
        <span className="banner-t">{t('library.readOnlyBanner')}</span>
      </div>
    </div>
  )
}
