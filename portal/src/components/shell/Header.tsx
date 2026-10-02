import { memo } from 'react'
import { useTranslation } from 'react-i18next'
import { BOOT } from '../../lib/boot'
import { fmtSpeed, IDLE_RATE } from '../../lib/format'
import { Icon } from '../ui/Icon'
import { TotalSpeedChart } from '../ui/SpeedChart'

export type Connection = 'live' | 'reconnecting' | 'connecting'

export function connectionOf(live: boolean, loaded: boolean): Connection {
  return live ? 'live' : loaded ? 'reconnecting' : 'connecting'
}

interface HeaderProps {
  connection: Connection
  downSpeed: number
  upSpeed: number
  /** Library only: the detail sheet's toggle. */
  showPanelToggle: boolean
  panelOpen: boolean
  onTogglePanel: () => void
  onUserMenu: (anchor: DOMRect) => void
  userMenuOpen: boolean
}

/**
 * The portal's title bar, after the mockup's browser frame: logo, wordmark and WEB badge; the
 * connection pill; the queue's live rates with a one-minute trend; the account chip.
 */
export const Header = memo(function Header({
  connection,
  downSpeed,
  upSpeed,
  showPanelToggle,
  panelOpen,
  onTogglePanel,
  onUserMenu,
  userMenuOpen,
}: HeaderProps) {
  const { t } = useTranslation()
  const down = fmtSpeed(downSpeed, IDLE_RATE)
  const up = fmtSpeed(upSpeed, IDLE_RATE)
  const pill = connection === 'live' ? 'pill good' : connection === 'reconnecting' ? 'pill warn' : 'pill'

  return (
    <header className="topbar">
      {/* "Goel°" is the product name, not copy — it stays out of the catalogue. */}
      <div className="brand">
        <span className="logo" aria-hidden="true">
          g
        </span>
        <span className="wm">
          Goel<sup>°</sup>
        </span>
        <span className="badge">{t('topbar.web')}</span>
      </div>

      <span className="sp" />

      <span
        className={`${pill} conn conn-${connection}`}
        role="status"
        title={
          connection === 'live'
            ? t('shell.conn.liveLong')
            : connection === 'reconnecting'
              ? t('shell.conn.reconnectingLong')
              : undefined
        }
      >
        <span className="conn-l">{t(`shell.conn.${connection}`)}</span>
      </span>

      <span className="rates">
        <span className="rates-chart">
          <TotalSpeedChart height={22} grid={0} showUp={false} endDot={false} label={t('topbar.speedTrend')} />
        </span>
        <span className="mono" aria-label={t('shell.rates', { down, up })} role="group">
          <span className="acc" aria-hidden="true">
            ↓ {down}
          </span>
          <span className="upc rates-up" aria-hidden="true">
            ↑ {up}
          </span>
        </span>
      </span>

      {showPanelToggle && (
        <button
          type="button"
          className="ibtn panel-toggle"
          onClick={onTogglePanel}
          aria-pressed={panelOpen}
          aria-label={t('topbar.detailPanel')}
          title={t('topbar.detailPanel')}
        >
          <Icon name="panel" />
        </button>
      )}

      <button
        type="button"
        className="chip user"
        onClick={(e) => onUserMenu(e.currentTarget.getBoundingClientRect())}
        aria-label={t('topbar.accountMenu', { username: BOOT.username })}
        aria-haspopup="menu"
        aria-expanded={userMenuOpen}
      >
        <Icon name="user" size="s" />
        <span className="uname">{BOOT.username}</span>
        <Icon name="chevronDown" size="s" />
      </button>
    </header>
  )
})
