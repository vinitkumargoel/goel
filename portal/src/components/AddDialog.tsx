import { useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
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
  const { t } = useTranslation()
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
      onWarn(t('addDialog.pickInterface'))
      return null
    }
    if (chosen.length === 1) return `single:${chosen[0]}`
    return chosen.length === eligible.length ? 'aggregate' : `aggregate:${chosen.join(',')}`
  }

  async function submit() {
    const trimmed = url.trim()
    if (!trimmed) {
      onWarn(t('addDialog.enterUrl'))
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
          <h3>{t('addDialog.title')}</h3>
        </div>

        <div className="mbody">
          <label className="flabel">{t('addDialog.urlLabel')}</label>
          <textarea
            className="finput"
            ref={urlRef}
            value={url}
            onChange={(e) => setUrl(e.target.value)}
            placeholder={t('addDialog.urlPlaceholder')}
          />
          <div className="fhint">{t('addDialog.urlHint')}</div>

          <div className="twocol">
            <div className="fg">
              <label className="flabel">
                {t('addDialog.saveTo')}{' '}
                <span className="chip chip-w">{t('addDialog.serverFolder')}</span>
              </label>
              {/* Read-only on purpose: a typed absolute path is refused only after the request is composed. */}
              <div className="finput pkfield">
                <span className={`pkval${folder ? '' : ' dim'}`} title={folder || undefined}>
                  {folder ? folderLabel(folder, home) : t('addDialog.defaultFolder')}
                </span>
                <button className="btn ghost pkbrowse" onClick={() => setPicking(true)}>
                  {t('addDialog.browse')}
                </button>
                {folder && (
                  <button
                    className="btn ghost pkclear"
                    onClick={() => setFolder('')}
                    title={t('addDialog.useDefaultFolder')}
                    aria-label={t('addDialog.useDefaultFolder')}
                  >
                    <CloseIcon />
                  </button>
                )}
              </div>
            </div>
            <div className="fg" style={{ flex: '0 0 130px' }}>
              <label className="flabel">{t('addDialog.priority')}</label>
              <select
                className="finput"
                value={priority}
                onChange={(e) => setPriority(e.target.value as 'normal' | 'high' | 'low')}
              >
                <option value="normal">{t('task.priority.normal')}</option>
                <option value="high">{t('task.priority.high')}</option>
                <option value="low">{t('task.priority.low')}</option>
              </select>
            </div>
          </div>

          {showNetworkChoice && net && (
            <div className="fg" style={{ marginTop: 14 }}>
              <label className="flabel">{t('addDialog.network')}</label>
              <select
                className="finput"
                value={mode}
                onChange={(e) => setMode(e.target.value as NetMode)}
              >
                <option value="auto">
                  {net.aggregation
                    ? t('addDialog.modeAutoSplit')
                    : t('addDialog.modeAutoDefault')}
                </option>
                <option value="split">{t('addDialog.modeSplit')}</option>
                <option value="single">{t('addDialog.modeSingle')}</option>
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
                {t('addDialog.splitHint', { count: eligible.length })}
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
            {t('addDialog.addPaused')}
          </label>
        </div>

        <div className="mfoot">
          <button className="btn" onClick={onClose}>
            {t('common.cancel')}
          </button>
          <button className="btn primary" onClick={submit} disabled={busy}>
            {busy ? t('addDialog.adding') : t('addDialog.submit')}
          </button>
        </div>
      </div>
    </>
  )
}

export function AdapterLine({ adapter }: { adapter: NetworkAdapter }) {
  const { t } = useTranslation()
  return (
    <span>
      {adapter.label}{' '}
      <span style={{ color: 'var(--text-faint)' }}>
        {adapter.ipv4 ?? t('network.noAddress')}
      </span>
      {adapter.expensive && <span className="chip chip-d">{t('network.metered')}</span>}
    </span>
  )
}
