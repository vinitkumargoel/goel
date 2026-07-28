import { useEffect, useRef, useState } from 'react'
import { api } from '../lib/api'
import { BOOT } from '../lib/boot'
import type { AddRequest, NetworkAdapter, NetworkState } from '../lib/types'
import { FolderPicker, folderLabel } from './FolderPicker'
import { CloseIcon, LinkIcon } from './Icons'

type NetMode = 'auto' | 'split' | 'single'

interface AddDialogProps {
  onClose: () => void
  onAdded: (added: number, refused: number) => void
  onWarn: (message: string) => void
}

export function AddDialog({ onClose, onAdded, onWarn }: AddDialogProps) {
  const [url, setUrl] = useState('')
  const [folder, setFolder] = useState('')
  const [priority, setPriority] = useState<'normal' | 'high' | 'low'>('normal')
  const [paused, setPaused] = useState(false)
  const [net, setNet] = useState<NetworkState | null>(null)
  const [mode, setMode] = useState<NetMode>('auto')
  const [chosen, setChosen] = useState<string[]>([])
  const [single, setSingle] = useState('')
  const [busy, setBusy] = useState(false)
  const [picking, setPicking] = useState(false)
  const [home, setHome] = useState<string | null>(null)
  const urlRef = useRef<HTMLTextAreaElement>(null)

  useEffect(() => {
    urlRef.current?.focus()
  }, [])

  useEffect(() => {
    let cancelled = false
    void api
      .network()
      .then((n) => {
        if (cancelled) return
        setNet(n)
        const eligible = n.adapters.filter((a) => a.eligible)
        setChosen(eligible.map((a) => a.name))
        setSingle(eligible[0]?.name ?? '')
      })
      .catch(() => {
        // Swallowed on purpose: without the picker the add still works on the server's default route.
      })
    return () => {
      cancelled = true
    }
  }, [])

  const eligible: NetworkAdapter[] = net?.adapters.filter((a) => a.eligible) ?? []
  const showNetworkChoice = eligible.length >= 2

  /** Returns null when the choice is unusable, having already warned; callers must not warn again. */
  function networkSpec(): string | null {
    if (!showNetworkChoice) return 'auto'
    if (mode === 'single') return single ? `single:${single}` : 'auto'
    if (mode !== 'split') return 'auto'
    if (chosen.length === 0) {
      onWarn('Pick at least one interface')
      return null
    }
    if (chosen.length === 1) return `single:${chosen[0]}`
    return chosen.length === eligible.length ? 'aggregate' : `aggregate:${chosen.join(',')}`
  }

  async function submit() {
    const trimmed = url.trim()
    if (!trimmed) {
      onWarn('Enter a URL or magnet first')
      return
    }
    const network = networkSpec()
    if (network === null) return

    const body: AddRequest = {
      url: trimmed,
      folder: folder.trim(),
      priority,
      paused,
      network,
    }

    setBusy(true)
    try {
      const result = await api.add(body)
      onAdded(result.added, result.refused)
    } catch {
      // `api` already surfaced the refusal; staying open keeps the user's typed URL.
      setBusy(false)
    }
  }

  return (
    <>
      {picking && (
        <FolderPicker
          initialPath={folder}
          canCreate={!BOOT.readOnly}
          onWarn={onWarn}
          onClose={() => setPicking(false)}
          onPick={(path, listing) => {
            setHome(listing.home)
            // Store the configured default as blank so changing it later still applies here.
            setFolder(path === listing.defaultFolder ? '' : path)
            setPicking(false)
          }}
        />
      )}
      <div className="modal">
        <div className="mhead">
          <div className="mic">
            <LinkIcon />
          </div>
          <h3>Add download</h3>
        </div>

        <div className="mbody">
          <label className="flabel">URL, magnet, FTP or SFTP link</label>
          <textarea
            className="finput"
            ref={urlRef}
            value={url}
            onChange={(e) => setUrl(e.target.value)}
            placeholder={'https://example.com/file.iso\nmagnet:?xt=urn:btih:...\nsftp://user@host/path/file.zip'}
          />
          <div className="fhint">
            Paste multiple lines to batch-add. Torrents/files download to the server running Goel°.
          </div>

          <div className="twocol">
            <div className="fg">
              <label className="flabel">
                Save to <span className="chip chip-w">Server folder</span>
              </label>
              {/* Read-only on purpose: a typed absolute path is refused only after the request is composed. */}
              <div className="finput pkfield">
                <span className={`pkval${folder ? '' : ' dim'}`} title={folder || undefined}>
                  {folder ? folderLabel(folder, home) : 'Default downloads folder'}
                </span>
                <button className="btn ghost pkbrowse" onClick={() => setPicking(true)}>
                  Browse…
                </button>
                {folder && (
                  <button
                    className="btn ghost pkclear"
                    onClick={() => setFolder('')}
                    title="Use the default folder"
                    aria-label="Use the default folder"
                  >
                    <CloseIcon />
                  </button>
                )}
              </div>
            </div>
            <div className="fg" style={{ flex: '0 0 130px' }}>
              <label className="flabel">Priority</label>
              <select
                className="finput"
                value={priority}
                onChange={(e) => setPriority(e.target.value as 'normal' | 'high' | 'low')}
              >
                <option value="normal">Normal</option>
                <option value="high">High</option>
                <option value="low">Low</option>
              </select>
            </div>
          </div>

          {showNetworkChoice && net && (
            <div className="fg" style={{ marginTop: 14 }}>
              <label className="flabel">Network</label>
              <select
                className="finput"
                value={mode}
                onChange={(e) => setMode(e.target.value as NetMode)}
              >
                <option value="auto">
                  Automatic —{' '}
                  {net.aggregation
                    ? 'split across every eligible interface'
                    : 'use the system default route'}
                </option>
                <option value="split">Split this download across interfaces</option>
                <option value="single">Send it all through one interface</option>
              </select>

              {mode === 'split' && (
                <div style={{ marginTop: 8 }}>
                  {eligible.map((a) => (
                    <label
                      key={a.name}
                      style={{
                        display: 'flex',
                        alignItems: 'center',
                        gap: 8,
                        fontSize: 12.5,
                        padding: '3px 0',
                        cursor: 'pointer',
                      }}
                    >
                      <input
                        type="checkbox"
                        checked={chosen.includes(a.name)}
                        onChange={(e) =>
                          setChosen((c) =>
                            e.target.checked ? [...c, a.name] : c.filter((n) => n !== a.name),
                          )
                        }
                      />
                      <AdapterLine adapter={a} />
                    </label>
                  ))}
                </div>
              )}

              {mode === 'single' && (
                <select
                  className="finput"
                  style={{ marginTop: 8 }}
                  value={single}
                  onChange={(e) => setSingle(e.target.value)}
                >
                  {eligible.map((a) => (
                    <option key={a.name} value={a.name}>
                      {a.label}
                      {a.ipv4 ? ` — ${a.ipv4}` : ''}
                    </option>
                  ))}
                </select>
              )}

              <div className="fhint">
                This machine has {eligible.length} usable interfaces. Splitting only helps when each
                has its own upstream link — two adapters behind the same router share one pipe and are
                usually slower together than the faster one alone.
              </div>
            </div>
          )}

          <label
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: 8,
              marginTop: 14,
              fontSize: 12.5,
              cursor: 'pointer',
            }}
          >
            <input type="checkbox" checked={paused} onChange={(e) => setPaused(e.target.checked)} />{' '}
            Add paused
          </label>
        </div>

        <div className="mfoot">
          <button className="btn" onClick={onClose}>
            Cancel
          </button>
          <button className="btn primary" onClick={submit} disabled={busy}>
            {busy ? 'Adding…' : 'Add to queue'}
          </button>
        </div>
      </div>
    </>
  )
}

export function AdapterLine({ adapter }: { adapter: NetworkAdapter }) {
  return (
    <span>
      {adapter.label} <span style={{ color: 'var(--text-faint)' }}>{adapter.ipv4 ?? 'no address'}</span>
      {adapter.expensive && <span className="chip chip-d">Metered</span>}
    </span>
  )
}
