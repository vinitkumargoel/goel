import { useEffect, useState } from 'react'
import { Trans, useTranslation } from 'react-i18next'
import type { ToastTone } from '../hooks/useToasts'
import { api } from '../lib/api'
import { BOOT } from '../lib/boot'
import type { Bandwidth } from '../hooks/useBandwidth'
import {
  applyTheme,
  AUTO_THEME,
  THEME_ACCENT,
  THEME_LABEL,
  THEMES,
  type ThemeChoice,
} from '../lib/theme'
import { BandwidthCard } from './BandwidthCard'
import { LogoutIcon, WarnIcon } from './Icons'
import { NetworkCard } from './NetworkCard'

interface SettingsViewProps {
  theme: ThemeChoice
  onTheme: (theme: ThemeChoice) => void
  canWrite: boolean
  onToast: (message: string, tone?: ToastTone) => void
  bandwidth?: Bandwidth
  /** Some server card holds edits nobody saved; App asks before leaving the page. */
  onDirtyChange?: (dirty: boolean) => void
}

/**
 * Two groups, because they differ in reach: "This browser" changes only this tab's look and
 * session; "Server" changes the daemon, and so every client signed in to it.
 */
export function SettingsView({ theme, onTheme, canWrite, onToast, bandwidth, onDirtyChange }: SettingsViewProps) {
  const { t } = useTranslation()
  const [bandwidthDirty, setBandwidthDirty] = useState(false)
  const [networkDirty, setNetworkDirty] = useState(false)
  const dirty = bandwidthDirty || networkDirty
  useEffect(() => onDirtyChange?.(dirty), [dirty, onDirtyChange])
  // Unmounting drops the edits with the cards, so nothing is pending any more.
  useEffect(() => () => onDirtyChange?.(false), [onDirtyChange])
  const linux = BOOT.host === 'linux'

  const pick = (choice: ThemeChoice, label: string) => {
    applyTheme(choice, true)
    onTheme(choice)
    onToast(t('settings.theme.toast', { theme: label }))
  }

  return (
    <div className="view">
      <div className="pad">
        <div className="ph">{t('common.settings')}</div>
        <div className="psub">{linux ? t('settings.subtitleLinux') : t('settings.subtitle')}</div>

        <h2 className="sgroup">{t('settings.group.browser')}</h2>

        <div className="card pd">
          <div className="srow">
            <div className="sinfo">
              <div className="sname">{t('settings.theme.name')}</div>
              <div className="sdesc">
                <Trans i18nKey="settings.theme.desc" components={{ bold: <b /> }} />
              </div>
            </div>
          </div>
          <div className="seg">
            <button
              className={theme === AUTO_THEME ? 'on' : ''}
              aria-pressed={theme === AUTO_THEME}
              onClick={() => pick(AUTO_THEME, t('settings.theme.auto'))}
            >
              <span className="sw sw-auto" aria-hidden="true" />
              {t('settings.theme.auto')}
            </button>
            {/* Theme names are product nomenclature shared with the desktop app, so they stay verbatim. */}
            {THEMES.map((name) => (
              <button
                key={name}
                className={name === theme ? 'on' : ''}
                aria-pressed={name === theme}
                onClick={() => pick(name, THEME_LABEL[name])}
              >
                <span className="sw" style={{ background: THEME_ACCENT[name] }} />
                {THEME_LABEL[name]}
              </button>
            ))}
          </div>
        </div>

        <div className="card pd">
          <div className="srow">
            <div className="sinfo">
              <div className="sname">
                {t('settings.access.name')}{' '}
                <span className={`chip ${BOOT.readOnly ? 'chip-d' : 'chip-w'}`}>
                  {BOOT.readOnly ? t('settings.access.readOnly') : t('settings.access.fullControl')}
                </span>
              </div>
              <div className="sdesc">
                <Trans
                  i18nKey="settings.access.signedInAs"
                  values={{ username: BOOT.username }}
                  components={{ bold: <b /> }}
                />{' '}
                {BOOT.readOnly
                  ? t('settings.access.descReadOnly')
                  : t('settings.access.descFull')}
              </div>
            </div>
          </div>
        </div>

        <div className="card pd">
          <div className="srow">
            <div className="sinfo">
              <div className="sname">{t('common.signOut')}</div>
              <div className="sdesc">{t('settings.signOut.desc')}</div>
            </div>
            <div className="sctl">
              <button className="btn" onClick={() => void api.logout()}>
                <LogoutIcon /> {t('common.signOut')}
              </button>
            </div>
          </div>
        </div>

        <h2 className="sgroup">
          {BOOT.hostname
            ? t('settings.group.serverNamed', { host: BOOT.hostname })
            : t('settings.group.server')}{' '}
          <span className="chip chip-d">{t('settings.group.everyClient')}</span>
        </h2>

        {bandwidth && (
          <BandwidthCard bandwidth={bandwidth} canWrite={canWrite} onToast={onToast} onDirty={setBandwidthDirty} />
        )}

        <NetworkCard canWrite={canWrite} onToast={onToast} onDirty={setNetworkDirty} />

        <div className="card pd">
          <div className="srow">
            <div className="sinfo">
              <div className="sname">
                {t('settings.desktop.name')}{' '}
                <span className="chip chip-d">
                  <WarnIcon />
                  {linux ? t('settings.desktop.chipLinux') : t('settings.desktop.chip')}
                </span>
              </div>
              <div className="sdesc">
                {linux ? (
                  <Trans i18nKey="settings.desktop.descLinux" components={{ cmd: <b />, path: <b /> }} />
                ) : (
                  t('settings.desktop.desc')
                )}
              </div>
            </div>
          </div>
        </div>

      </div>
    </div>
  )
}
