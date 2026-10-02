import { useCallback, useEffect, useId, useState } from 'react'
import { Trans, useTranslation } from 'react-i18next'
import type { ToastTone } from '../../hooks/useToasts'
import { api, failureMessage } from '../../lib/api'
import type { NetworkAdapter, NetworkState } from '../../lib/types'
import { Switch } from '../ui/Controls'
import { Icon } from '../ui/Icon'
import { DirtyStrip, Pill, SavedTick, SettingsCard, useSavedFlash } from './SettingsParts'

interface NetworkCardProps {
  canWrite: boolean
  onToast: (m: string, tone?: ToastTone) => void
  /** Unticked adapters or a changed stream count are waiting for Save. */
  onDirty?: (dirty: boolean) => void
}

/** The ticked set the daemon means: an empty `selected` is "every eligible adapter", not "none". */
function tickedOf(n: NetworkState): string[] {
  return n.selected.length === 0 ? n.adapters.filter((a) => a.eligible).map((a) => a.name) : n.selected
}

function sameSet(a: string[], b: string[]): boolean {
  return a.length === b.length && a.every((x) => b.includes(x))
}

const STREAMS = [1, 2, 3, 4, 5, 6, 7, 8]

/**
 * Settings › Network: the split switch applies at once; interface and stream edits wait in a strip
 * with Save and Discard, so leaving the page can ask before dropping them.
 */
export function NetworkCard({ canWrite, onToast, onDirty }: NetworkCardProps) {
  const { t } = useTranslation()
  const id = useId()
  const [busy, setBusy] = useState(false)
  const [splitSaved, flashSplit] = useSavedFlash()
  const [editsSaved, flashEdits] = useSavedFlash()
  const [net, setNet] = useState<NetworkState | null>(null)
  const [failed, setFailed] = useState(false)
  const [ticked, setTicked] = useState<string[]>([])
  const [streams, setStreams] = useState(2)

  const adopt = useCallback((n: NetworkState) => {
    setNet(n)
    setStreams(n.streamsPerAdapter)
    setTicked(tickedOf(n))
  }, [])

  const dirty = net != null && (streams !== net.streamsPerAdapter || !sameSet(ticked, tickedOf(net)))
  useEffect(() => onDirty?.(dirty), [dirty, onDirty])

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

  async function save(body: Parameters<typeof api.updateNetwork>[0], flash: () => void) {
    setBusy(true)
    try {
      // Adopt the echoed state, never `body`: the server can settle on something else.
      adopt(await api.updateNetwork(body))
      flash()
    } catch (e) {
      const message = failureMessage(e)
      if (message) onToast(message, 'warn')
    } finally {
      setBusy(false)
    }
  }

  if (failed || !net) {
    return (
      <SettingsCard title={t('pages.settings.network')} icon="wifi">
        <p className="srow small muted" role={failed ? 'alert' : 'status'}>
          {failed ? t('settings.network.readError') : t('settings.network.loading')}
        </p>
      </SettingsCard>
    )
  }

  const eligibleNames = net.adapters.filter((a) => a.eligible).map((a) => a.name)
  const canSplit = eligibleNames.length >= 2
  // Membership, not count: a ticked-but-ineligible adapter makes a count read "all eligible" wrongly.
  const allEligibleTicked = eligibleNames.every((n) => ticked.includes(n))
  const nothingTicked = ticked.length === 0

  return (
    <SettingsCard title={t('pages.settings.network')} icon="wifi" className="set-net">
      <div className="srow">
        <div className="sl">
          <b id={`${id}-split`}>{t('settings.network.splitName')}</b>
          <span id={`${id}-splitd`}>
            {canSplit ? t('settings.network.splitDesc') : t('settings.network.splitDescSingle')}
          </span>
        </div>
        <SavedTick shown={splitSaved} />
        {canWrite && canSplit ? (
          <Switch
            checked={net.aggregation}
            disabled={busy}
            labelledBy={`${id}-split`}
            describedBy={`${id}-splitd`}
            onChange={(on) => void save({ aggregation: on }, flashSplit)}
          />
        ) : (
          <Pill tone={net.aggregation ? 'acc' : undefined}>{net.aggregation ? t('common.on') : t('common.off')}</Pill>
        )}
      </div>

      {/* `net.reason` is the daemon's diagnostic text, interpolated as-is. */}
      {net.aggregation && net.reason && (
        <div className="note bad set-note">
          <Icon name="alert" />
          <span>{t('settings.network.notSplitting', { reason: net.reason })}</span>
        </div>
      )}

      {net.locked && (
        <div className="note warn set-note">
          <Icon name="lock" />
          <span>
            <Trans i18nKey="settings.network.lockedDesc" components={{ path: <b />, cmd: <b /> }} />
          </span>
        </div>
      )}

      <div className="srow set-col">
        <div className="row">
          <div className="sl">
            <b id={`${id}-ifs`}>{t('settings.network.interfaces')}</b>
            <span>{t('settings.network.interfacesDesc')}</span>
          </div>
          <SavedTick shown={editsSaved} />
        </div>
        <ul className="set-ifs" aria-labelledby={`${id}-ifs`}>
          {net.adapters.map((a) => (
            <li key={a.name}>
              <label className={`set-if${a.eligible ? '' : ' off'}`}>
                <input
                  type="checkbox"
                  className="check"
                  checked={ticked.includes(a.name)}
                  disabled={!(canWrite && a.eligible)}
                  onChange={(e) =>
                    setTicked((c) => (e.target.checked ? [...c, a.name] : c.filter((n) => n !== a.name)))
                  }
                />
                <AdapterLabel adapter={a} />
                {!a.eligible && <Pill>{t('settings.network.unavailable')}</Pill>}
              </label>
            </li>
          ))}
        </ul>
      </div>

      <div className="srow">
        <div className="sl">
          <b>
            <label htmlFor={`${id}-streams`}>{t('settings.network.streamsName')}</label>
          </b>
          <span>{t('settings.network.streamsDesc')}</span>
        </div>
        <div className="field sm select set-streams">
          <select
            id={`${id}-streams`}
            value={streams}
            disabled={!canWrite}
            onChange={(e) => setStreams(Number(e.target.value))}
          >
            {STREAMS.map((i) => (
              <option key={i} value={i}>
                {i}
              </option>
            ))}
          </select>
          <Icon name="chevronDown" size="s" />
        </div>
      </div>

      {canWrite && (
        <>
          <p className="help set-apply">{t('settings.network.applyDesc')}</p>
          <DirtyStrip
            dirty={dirty}
            busy={busy}
            onDiscard={() => adopt(net)}
            saveDisabled={nothingTicked}
            saveTitle={nothingTicked ? t('settings.network.tickAtLeastOne') : undefined}
            onSave={() =>
              void save(
                // All-ticked sends `[]` (the "every eligible" sentinel) so a NIC added later isn't excluded.
                { adapters: allEligibleTicked ? [] : ticked, streams },
                flashEdits,
              )
            }
          />
        </>
      )}
    </SettingsCard>
  )
}

/** "Wi-Fi 10.0.0.2", with Metered for an expensive link. */
function AdapterLabel({ adapter }: { adapter: NetworkAdapter }) {
  const { t } = useTranslation()
  return (
    <span className="set-if-t">
      <span>{adapter.label}</span>
      <span className="mono small muted">{adapter.ipv4 ?? t('adapter.noAddress')}</span>
      {adapter.expensive && <Pill tone="warn">{t('adapter.metered')}</Pill>}
    </span>
  )
}
