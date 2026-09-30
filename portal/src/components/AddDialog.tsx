import { useEffect, useId, useRef, useState, type KeyboardEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { useDialogFocus } from '../hooks/useDialogFocus'
import { api } from '../lib/api'
import { BOOT } from '../lib/boot'
import { summarizeLinks } from '../lib/links'
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
  const [error, setError] = useState<string | null>(null)
  const urlRef = useRef<HTMLTextAreaElement>(null)
  const modalRef = useRef<HTMLDivElement>(null)
  const id = useId()
  // The folder picker stacks its own modal on top; while it's open, Tab belongs to it.
  const trapTab = useDialogFocus(modalRef, !picking)
  const links = summarizeLinks(url)

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
    if (busy) return
    const trimmed = url.trim()
    if (!trimmed) {
      setError(t('addDialog.enterUrl'))
      urlRef.current?.focus()
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

  function onKeyDown(e: KeyboardEvent<HTMLDivElement>) {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
      e.preventDefault()
      void submit()
      return
    }
    trapTab(e)
  }

  const errorId = `${id}-error`
  const countId = `${id}-count`

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
      <div
        className="modal"
        ref={modalRef}
        role="dialog"
        aria-modal="true"
        aria-labelledby={`${id}-title`}
        onKeyDown={onKeyDown}
      >
        <div className="mhead">
          <div className="mic">
            <LinkIcon />
          </div>
          <h3 id={`${id}-title`}>{t('addDialog.title')}</h3>
        </div>

        <div className="mbody">
          <label className="flabel" htmlFor={`${id}-url`}>
            {t('addDialog.urlLabel')}
          </label>
          <textarea
            id={`${id}-url`}
            className="finput"
            ref={urlRef}
            value={url}
            onChange={(e) => {
              setUrl(e.target.value)
              setError(null)
            }}
            placeholder={t('addDialog.urlPlaceholder')}
            aria-invalid={error ? true : undefined}
            aria-describedby={`${error ? errorId : countId} ${id}-hint`}
          />
          {error ? (
            <div className="ferr" id={errorId} role="alert">
              {error}
            </div>
          ) : (
            <LinkCount id={countId} valid={links.valid} unsupported={links.unsupported} />
          )}
          <div className="fhint" id={`${id}-hint`}>
            {t('addDialog.urlHint')}{' '}
            <span className="kbd-hint">{t('addDialog.submitShortcut')}</span>
          </div>

          <div className="twocol">
            <div className="fg">
              <div className="flabel" id={`${id}-folder`}>
                {t('addDialog.saveTo')}{' '}
                <span className="chip chip-w">{t('addDialog.serverFolder')}</span>
              </div>
              {/* Read-only on purpose: a typed absolute path is refused only after the request is composed. */}
              <div className="finput pkfield" role="group" aria-labelledby={`${id}-folder`}>
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
              <label className="flabel" htmlFor={`${id}-prio`}>
                {t('addDialog.priority')}
              </label>
              <select
                id={`${id}-prio`}
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
              <label className="flabel" htmlFor={`${id}-net`}>
                {t('addDialog.network')}
              </label>
              <select
                id={`${id}-net`}
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
                  aria-label={t('addDialog.modeSingle')}
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
      <span style={{ color: 'var(--text-dim)' }}>
        {adapter.ipv4 ?? t('adapter.noAddress')}
      </span>
      {adapter.expensive && <span className="chip chip-d">{t('adapter.metered')}</span>}
    </span>
  )
}

interface LinkCountProps {
  id: string
  valid: number
  unsupported: { text: string }[]
}

/** Live feedback on a multi-line paste: how many links will queue, and which lines look wrong. */
function LinkCount({ id, valid, unsupported }: LinkCountProps) {
  const { t } = useTranslation()
  const first = unsupported[0]
  return (
    <div className="fcount" id={id} aria-live="polite">
      {(valid > 0 || first) && <span>{t('addDialog.linksDetected', { count: valid })}</span>}
      {first && (
        <span className="fwarn">
          {' · '}
          {t('addDialog.unsupportedLines', { count: unsupported.length, example: first.text })}
        </span>
      )}
    </div>
  )
}
