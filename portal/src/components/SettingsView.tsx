import { useCallback, useEffect, useState } from 'react'
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
  return (
    <div className="view">
      <div className="pad">
        <div className="ph">Settings</div>
        <div className="psub">
          These apply to your browser. Server options (port, sign-in, password) are managed in the
          desktop app under Settings → Web Access.
        </div>

        <div className="card pd">
          <div className="srow">
            <div className="sinfo">
              <div className="sname">Web theme</div>
              <div className="sdesc">
                Independent of the desktop app — this choice is remembered in <b>this browser</b>{' '}
                only. The desktop sets the default a new browser starts with.
              </div>
            </div>
          </div>
          <div className="seg">
            {THEMES.map((t) => (
              <button
                key={t}
                className={t === theme ? 'on' : ''}
                onClick={() => {
                  applyTheme(t, true)
                  onTheme(t)
                  onToast(`Theme: ${THEME_LABEL[t]}`)
                }}
              >
                <span className="sw" style={{ background: THEME_ACCENT[t] }} />
                {THEME_LABEL[t]}
              </button>
            ))}
          </div>
        </div>

        <div className="card pd">
          <div className="srow">
            <div className="sinfo">
              <div className="sname">
                Access{' '}
                <span className={`chip ${BOOT.readOnly ? 'chip-d' : 'chip-w'}`}>
                  {BOOT.readOnly ? 'Read-only' : 'Full control'}
                </span>
              </div>
              <div className="sdesc">
                Signed in as <b>{BOOT.username}</b>.{' '}
                {BOOT.readOnly
                  ? 'This session can view and stream but not change downloads.'
                  : 'This session can add, remove, and manage downloads.'}
              </div>
            </div>
          </div>
          <div className="srow">
            <div className="sinfo">
              <div className="sname">
                Managed on the desktop{' '}
                <span className="chip chip-d">
                  <WarnIcon />
                  Desktop
                </span>
              </div>
              <div className="sdesc">
                Port, sign-in username/password, LAN access, read-only, and session length live in
                the app (Settings → Web Access). A native folder picker, Reveal in Finder, clipboard
                capture, and notifications also stay on the Mac running Goel°.
              </div>
            </div>
          </div>
        </div>

        <NetworkCard canWrite={canWrite} onToast={onToast} />

        <div className="card pd">
          <div className="srow">
            <div className="sinfo">
              <div className="sname">Sign out</div>
              <div className="sdesc">End this browser session.</div>
            </div>
            <div className="sctl">
              <button className="btn" onClick={() => void api.logout()}>
                <LogoutIcon /> Sign out
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
  )
}

function NetworkCard({ canWrite, onToast }: { canWrite: boolean; onToast: (m: string) => void }) {
  const [net, setNet] = useState<NetworkState | null>(null)
  const [failed, setFailed] = useState(false)
  const [ticked, setTicked] = useState<string[]>([])
  const [streams, setStreams] = useState(2)

  const adopt = useCallback((n: NetworkState) => {
    setNet(n)
    setStreams(n.streamsPerAdapter)
    // An empty `selected` means "every eligible adapter", not "none" — showing
    // it as all-unticked would misreport the server's actual state.
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
      // The server echoes the state it actually settled on, which can differ
      // from what was asked — adopt that, not the request.
      adopt(await api.updateNetwork(body))
      onToast('Network settings saved')
    } catch {
      // Already surfaced by the api layer.
    }
  }

  if (failed) {
    return (
      <div className="card pd">
        <p className="fhint" style={{ padding: 14 }}>
          Could not read the network configuration.
        </p>
      </div>
    )
  }

  if (!net) {
    return (
      <div className="card pd">
        <p className="fhint" style={{ padding: 8 }}>
          Loading network…
        </p>
      </div>
    )
  }

  const eligibleCount = net.adapters.filter((a) => a.eligible).length
  const canSplit = eligibleCount >= 2

  return (
    <div className="card pd">
      <div className="srow">
        <div className="sinfo">
          <div className="sname">
            Split downloads across interfaces{' '}
            <span className={`chip ${net.aggregation ? 'chip-w' : 'chip-d'}`}>
              {net.aggregation ? 'On' : 'Off'}
            </span>
          </div>
          <div className="sdesc">
            {canSplit
              ? 'Opens connections on several interfaces at once. Faster only when each interface has its own upstream link — two adapters behind the same router share one pipe and are usually slower together than the faster one alone.'
              : 'This machine has one usable interface, so there is nothing to split across.'}
          </div>
        </div>
        <div className="sctl">
          {canWrite && canSplit && (
            <button
              className={`btn${net.aggregation ? '' : ' primary'}`}
              onClick={() => void save({ aggregation: !net.aggregation })}
            >
              {net.aggregation ? 'Turn off' : 'Turn on'}
            </button>
          )}
        </div>
      </div>

      {net.aggregation && net.reason && (
        <div className="srow">
          <div className="sinfo">
            <div className="sdesc" style={{ color: 'var(--red)' }}>
              <WarnIcon /> Not splitting right now — {net.reason}
            </div>
          </div>
        </div>
      )}

      {net.locked && (
        <div className="srow">
          <div className="sinfo">
            <div className="sdesc">
              GOEL_AGGREGATION is set in <b>/etc/goel/config</b>, so a change made here is reverted
              the next time the service restarts. Run <b>goel config set aggregation on|off</b> on
              the server to make it permanent.
            </div>
          </div>
        </div>
      )}

      <div className="srow">
        <div className="sinfo">
          <div className="sname">Interfaces</div>
          <div className="sdesc">
            Ticked interfaces are the ones a split may use. Leave them all ticked to use every
            eligible one.
          </div>
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
              {!a.eligible && <span className="chip chip-d">Unavailable</span>}
            </label>
          )
        })}
      </div>

      <div className="srow">
        <div className="sinfo">
          <div className="sname">Connections per interface</div>
          <div className="sdesc">
            More streams help on high-latency links and hurt against servers that throttle per
            connection.
          </div>
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
            <div className="sdesc">
              Applies to new downloads; running ones keep the interfaces they started on.
            </div>
          </div>
          <div className="sctl">
            <button
              className="btn primary"
              onClick={() =>
                void save({
                  // All-ticked is sent as the empty "every eligible adapter"
                  // sentinel, so adding a NIC later is picked up automatically
                  // instead of being silently excluded by a stale list.
                  adapters: ticked.length === eligibleCount ? [] : ticked,
                  streams,
                })
              }
            >
              Save
            </button>
          </div>
        </div>
      )}
    </div>
  )
}
