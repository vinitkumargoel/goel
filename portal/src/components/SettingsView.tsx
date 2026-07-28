import { useCallback, useEffect, useState } from 'react'
import { Trans, useTranslation } from 'react-i18next'
import { api } from '../lib/api'
import { BOOT } from '../lib/boot'
import { applyTheme, THEME_ACCENT, THEME_LABEL, THEMES, type Theme } from '../lib/theme'
import type { NetworkState } from '../lib/types'
import { AdapterLine } from './AddDialog'
import { LogoutIcon, WarnIcon } from './Icons'

interface SettingsViewProps {
  theme: Theme
  onTheme: (theme: Theme) => void
  canWrite: boolean
  onToast: (message: string) => void
}

export function SettingsView({ theme, onTheme, canWrite, onToast }: SettingsViewProps) {
  const { t } = useTranslation()

  return (
    <div className="view">
      <div className="pad">
        <div className="ph">{t('common.settings')}</div>
        <div className="psub">{t('settings.subtitle')}</div>

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
            {/* Theme names are product nomenclature shared with the desktop app, so they stay verbatim. */}
            {THEMES.map((name) => (
              <button
                key={name}
                className={name === theme ? 'on' : ''}
                onClick={() => {
                  applyTheme(name, true)
                  onTheme(name)
                  onToast(t('settings.theme.toast', { theme: THEME_LABEL[name] }))
                }}
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
          <div className="srow">
            <div className="sinfo">
              <div className="sname">
                {t('settings.desktop.name')}{' '}
                <span className="chip chip-d">
                  <WarnIcon />
                  {t('settings.desktop.chip')}
                </span>
              </div>
              <div className="sdesc">{t('settings.desktop.desc')}</div>
            </div>
          </div>
        </div>

        <NetworkCard canWrite={canWrite} onToast={onToast} />

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
      </div>
    </div>
  )
}

function NetworkCard({ canWrite, onToast }: { canWrite: boolean; onToast: (m: string) => void }) {
  const { t } = useTranslation()
  const [net, setNet] = useState<NetworkState | null>(null)
  const [failed, setFailed] = useState(false)
  const [ticked, setTicked] = useState<string[]>([])
  const [streams, setStreams] = useState(2)

  const adopt = useCallback((n: NetworkState) => {
    setNet(n)
    setStreams(n.streamsPerAdapter)
    // An empty `selected` means "every eligible adapter", not "none" — all-unticked would misreport it.
    setTicked(
      n.selected.length === 0 ? n.adapters.filter((a) => a.eligible).map((a) => a.name) : n.selected,
    )
  }, [])

  useEffect(() => {
    let cancelled = false
    void api
      .network()
      .then((n) => {
        if (!cancelled) adopt(n)
      })
      .catch(() => {
        if (!cancelled) setFailed(true)
      })
    return () => {
      cancelled = true
    }
  }, [adopt])

  async function save(body: Parameters<typeof api.updateNetwork>[0]) {
    try {
      // Adopt the echoed state, never `body`: the server can settle on something else.
      adopt(await api.updateNetwork(body))
      onToast(t('settings.network.saved'))
    } catch {
      // Already surfaced by the api layer.
    }
  }

  if (failed) {
    return (
      <div className="card pd">
        <p className="fhint" style={{ padding: 14 }}>
          {t('settings.network.readError')}
        </p>
      </div>
    )
  }

  if (!net) {
    return (
      <div className="card pd">
        <p className="fhint" style={{ padding: 8 }}>
          {t('settings.network.loading')}
        </p>
      </div>
    )
  }

  const eligibleNames = net.adapters.filter((a) => a.eligible).map((a) => a.name)
  const canSplit = eligibleNames.length >= 2
  // Membership, not count: a ticked-but-ineligible adapter makes a count read "all eligible" wrongly.
  const allEligibleTicked = eligibleNames.every((n) => ticked.includes(n))
  const nothingTicked = ticked.length === 0

  return (
    <div className="card pd">
      <div className="srow">
        <div className="sinfo">
          <div className="sname">
            {t('settings.network.splitName')}{' '}
            <span className={`chip ${net.aggregation ? 'chip-w' : 'chip-d'}`}>
              {net.aggregation ? t('common.on') : t('common.off')}
            </span>
          </div>
          <div className="sdesc">
            {canSplit
              ? t('settings.network.splitDesc')
              : t('settings.network.splitDescSingle')}
          </div>
        </div>
        <div className="sctl">
          {canWrite && canSplit && (
            <button
              className={`btn${net.aggregation ? '' : ' primary'}`}
              onClick={() => void save({ aggregation: !net.aggregation })}
            >
              {net.aggregation ? t('common.turnOff') : t('common.turnOn')}
            </button>
          )}
        </div>
      </div>

      {/* `net.reason` is the daemon's diagnostic text, interpolated as-is. */}
      {net.aggregation && net.reason && (
        <div className="srow">
          <div className="sinfo">
            <div className="sdesc" style={{ color: 'var(--red)' }}>
              <WarnIcon /> {t('settings.network.notSplitting', { reason: net.reason })}
            </div>
          </div>
        </div>
      )}

      {net.locked && (
        <div className="srow">
          <div className="sinfo">
            <div className="sdesc">
              <Trans
                i18nKey="settings.network.lockedDesc"
                components={{ path: <b />, cmd: <b /> }}
              />
            </div>
          </div>
        </div>
      )}

      <div className="srow">
        <div className="sinfo">
          <div className="sname">{t('settings.network.interfaces')}</div>
          <div className="sdesc">{t('settings.network.interfacesDesc')}</div>
        </div>
      </div>
      <div style={{ padding: '0 2px 12px' }}>
        {net.adapters.map((a) => {
          const editable = canWrite && a.eligible
          return (
            <label
              key={a.name}
              style={{
                display: 'flex',
                alignItems: 'center',
                gap: 8,
                fontSize: 12.5,
                padding: '4px 0',
                cursor: editable ? 'pointer' : 'default',
                opacity: a.eligible ? 1 : 0.55,
              }}
            >
              <input
                type="checkbox"
                checked={ticked.includes(a.name)}
                disabled={!editable}
                onChange={(e) =>
                  setTicked((c) =>
                    e.target.checked ? [...c, a.name] : c.filter((n) => n !== a.name),
                  )
                }
              />
              <AdapterLine adapter={a} />
              {!a.eligible && <span className="chip chip-d">{t('settings.network.unavailable')}</span>}
            </label>
          )
        })}
      </div>

      <div className="srow">
        <div className="sinfo">
          <div className="sname">{t('settings.network.streamsName')}</div>
          <div className="sdesc">{t('settings.network.streamsDesc')}</div>
        </div>
        <div className="sctl">
          <select
            className="finput"
            style={{ width: 76 }}
            value={streams}
            disabled={!canWrite}
            onChange={(e) => setStreams(Number(e.target.value))}
          >
            {[1, 2, 3, 4, 5, 6, 7, 8].map((i) => (
              <option key={i} value={i}>
                {i}
              </option>
            ))}
          </select>
        </div>
      </div>

      {canWrite && (
        <div className="srow">
          <div className="sinfo">
            <div className="sdesc">{t('settings.network.applyDesc')}</div>
          </div>
          <div className="sctl">
            <button
              className="btn primary"
              disabled={nothingTicked}
              title={nothingTicked ? t('settings.network.tickAtLeastOne') : undefined}
              onClick={() =>
                void save({
                  // All-ticked sends `[]` (the "every eligible" sentinel) so a NIC added later isn't excluded.
                  adapters: allEligibleTicked ? [] : ticked,
                  streams,
                })
              }
            >
              {t('common.save')}
            </button>
          </div>
        </div>
      )}
    </div>
  )
}
