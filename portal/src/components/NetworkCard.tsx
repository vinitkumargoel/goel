import { useCallback, useEffect, useState } from 'react'
import { Trans, useTranslation } from 'react-i18next'
import type { ToastTone } from '../hooks/useToasts'
import { api, failureMessage } from '../lib/api'
import type { NetworkState } from '../lib/types'
import { AdapterLine } from './AddDialog'
import { WarnIcon } from './Icons'
import { DirtyStrip, SavedTick, useSavedFlash } from './SettingsParts'

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

/**
 * Settings → Network: the split switch applies at once; interface and stream edits wait in a strip
 * with Save and Discard, so leaving the page can ask before dropping them.
 */
export function NetworkCard({ canWrite, onToast, onDirty }: NetworkCardProps) {
  const { t } = useTranslation()
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
          <SavedTick shown={splitSaved} />
          {canWrite && canSplit && (
            <button
              className={`btn${net.aggregation ? '' : ' primary'}`}
              disabled={busy}
              onClick={() => void save({ aggregation: !net.aggregation }, flashSplit)}
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
        <div className="sctl">
          <SavedTick shown={editsSaved} />
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
        <>
          <p className="fhint sapply">{t('settings.network.applyDesc')}</p>
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
    </div>
  )
}
