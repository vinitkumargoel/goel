import { useEffect, useId, useState } from 'react'
import { Trans, useTranslation } from 'react-i18next'
import type { Bandwidth } from '../../hooks/useBandwidth'
import type { ToastTone } from '../../hooks/useToasts'
import { api } from '../../lib/api'
import { BOOT } from '../../lib/boot'
import { applyTheme, type ThemeChoice } from '../../lib/theme'
import { ToggleRow } from '../ui/Controls'
import { Icon } from '../ui/Icon'
import { BandwidthCard } from './BandwidthCard'
import { LanguageRow, NotifyRow } from './BrowserPrefsCard'
import { NetworkCard } from './NetworkCard'
import { ScheduleCard } from './ScheduleCard'
import { Pill, SettingsCard } from './SettingsParts'
import { ThemeTiles } from './ThemeTiles'

interface SettingsViewProps {
  theme: ThemeChoice
  onTheme: (theme: ThemeChoice) => void
  canWrite: boolean
  onToast: (message: string, tone?: ToastTone) => void
  bandwidth?: Bandwidth
  /** Some server card holds edits nobody saved; App asks before leaving the page. */
  onDirtyChange?: (dirty: boolean) => void
  /** Hide the detail panel while nothing is selected (else it shows the queue overview). */
  panelAutoHide?: boolean
  onPanelAutoHide?: (on: boolean) => void
}

/**
 * Two groups of cards, because they differ in reach: "This browser" changes only this tab's look
 * and session; "Server" changes the daemon, and so every client signed in to it.
 */
export function SettingsView({
  theme,
  onTheme,
  canWrite,
  onToast,
  bandwidth,
  onDirtyChange,
  panelAutoHide,
  onPanelAutoHide,
}: SettingsViewProps) {
  const { t } = useTranslation()
  const id = useId()
  const [bandwidthDirty, setBandwidthDirty] = useState(false)
  const [networkDirty, setNetworkDirty] = useState(false)
  const [scheduleDirty, setScheduleDirty] = useState(false)
  const dirty = bandwidthDirty || networkDirty || scheduleDirty
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
    <div className="pset">
      <header className="set-head">
        <div className="col set-head-t">
          <h1 className="h1">{t('common.settings')}</h1>
          <p className="small muted">{linux ? t('settings.subtitleLinux') : t('settings.subtitle')}</p>
        </div>
        <span className="small muted set-auto">
          <Icon name="check" size="s" />
          {t('pages.settings.autosave')}
        </span>
      </header>

      <section className="set-sect" aria-labelledby={`${id}-browser`}>
        <h2 className="h2 set-gh" id={`${id}-browser`}>
          {t('settings.group.browser')}
        </h2>
        <div className="set-cards">
          <SettingsCard title={t('pages.settings.appearance')} icon="sun">
            <ThemeTiles theme={theme} onPick={pick} />
            <LanguageRow />
          </SettingsCard>

          <SettingsCard title={t('pages.settings.behaviour')} icon="bell">
            <NotifyRow onToast={onToast} />
            {onPanelAutoHide && (
              <ToggleRow
                id={`${id}-panel`}
                title={t('settings.panel.name')}
                detail={t('settings.panel.desc')}
                checked={panelAutoHide ?? false}
                onChange={onPanelAutoHide}
              />
            )}
          </SettingsCard>

          <SettingsCard
            title={t('settings.access.name')}
            icon="user"
            aside={
              <Pill tone={BOOT.readOnly ? 'warn' : 'good'}>
                {BOOT.readOnly ? t('settings.access.readOnly') : t('settings.access.fullControl')}
              </Pill>
            }
          >
            <div className="srow">
              <div className="sl">
                <b>
                  <Trans i18nKey="settings.access.signedInAs" values={{ username: BOOT.username }} components={{ bold: <b /> }} />
                </b>
                <span>{BOOT.readOnly ? t('settings.access.descReadOnly') : t('settings.access.descFull')}</span>
              </div>
            </div>
            <div className="srow">
              <div className="sl">
                <b>{t('common.signOut')}</b>
                <span>{t('settings.signOut.desc')}</span>
              </div>
              <button type="button" className="btn sm" onClick={() => void api.logout()}>
                <Icon name="logout" size="s" />
                {t('common.signOut')}
              </button>
            </div>
          </SettingsCard>
        </div>
      </section>

      <section className="set-sect" aria-labelledby={`${id}-server`}>
        <h2 className="h2 set-gh" id={`${id}-server`}>
          {BOOT.hostname ? t('settings.group.serverNamed', { host: BOOT.hostname }) : t('settings.group.server')}{' '}
          <span className="pill nodot info">{t('settings.group.everyClient')}</span>
        </h2>
        <div className="set-cards">
          {bandwidth && (
            <BandwidthCard bandwidth={bandwidth} canWrite={canWrite} onToast={onToast} onDirty={setBandwidthDirty} />
          )}
          <NetworkCard canWrite={canWrite} onToast={onToast} onDirty={setNetworkDirty} />
          <SettingsCard
            title={t('settings.desktop.name')}
            icon={linux ? 'term' : 'server'}
            aside={<Pill tone="warn">{linux ? t('settings.desktop.chipLinux') : t('settings.desktop.chip')}</Pill>}
          >
            <p className="srow small muted set-desk">
              {linux ? (
                <Trans i18nKey="settings.desktop.descLinux" components={{ cmd: <b className="mono" />, path: <b className="mono" /> }} />
              ) : (
                t('settings.desktop.desc')
              )}
            </p>
          </SettingsCard>
          {!linux && <ScheduleCard canWrite={canWrite} onToast={onToast} onDirty={setScheduleDirty} />}
        </div>
      </section>
    </div>
  )
}
