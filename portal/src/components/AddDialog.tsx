import { useEffect, useId, useRef, useState, type KeyboardEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { useDialogFocus } from '../hooks/useDialogFocus'
import { saveDraft, type AddDraft } from '../lib/addDraft'
import { submitAdd, type AddSummary } from '../lib/addSubmit'
import { api, failureMessage } from '../lib/api'
import { BOOT } from '../lib/boot'
import { removeLine, summarizeLinks } from '../lib/links'
import { dragHasFiles, mergeTorrents, type TorrentMerge } from '../lib/torrentFiles'
import type { NetworkAdapter, NetworkState } from '../lib/types'
import { FolderPicker, folderLabel } from './FolderPicker'
import { CloseIcon, LinkIcon } from './Icons'
import { LinkIssues } from './LinkIssues'
import { TorrentDropZone } from './TorrentDropZone'

type NetMode = 'auto' | 'split' | 'single'

interface AddDialogProps {
  onClose: () => void
  onAdded: (summary: AddSummary) => void
  onWarn: (message: string) => void
  /** Torrent files dropped on the window, which opened the dialog. */
  initialFiles?: readonly File[]
  /** Links and choices typed before a sign-out cut them off, restored after signing back in. */
  initialDraft?: AddDraft | null
}

export function AddDialog({
  onClose,
  onAdded,
  onWarn,
  initialFiles = [],
  initialDraft = null,
}: AddDialogProps) {
  const { t } = useTranslation()
  const [url, setUrl] = useState(initialDraft?.url ?? '')
  const [torrents, setTorrents] = useState<TorrentMerge>(() => mergeTorrents([], initialFiles))
  const [folder, setFolder] = useState(initialDraft?.folder ?? '')
  const [priority, setPriority] = useState<'normal' | 'high' | 'low'>(initialDraft?.priority ?? 'normal')
  const [paused, setPaused] = useState(initialDraft?.paused ?? false)
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
  // The folder picker stacks its own modal on top; while it's open, Tab and Escape belong to it.
  useDialogFocus(modalRef, { trap: !picking, onEscape: onClose })
  const links = summarizeLinks(url)

  useEffect(() => {
    urlRef.current?.focus()
  }, [])

  // Kept as typed: an expired session reloads the page to sign in, and would otherwise lose it.
  useEffect(() => {
    saveDraft({ url, folder, priority, paused })
  }, [url, folder, priority, paused])

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

  const addFiles = (incoming: File[]) => {
    setTorrents((cur) => mergeTorrents(cur.files, incoming))
    setError(null)
  }

  async function submit() {
    if (busy) return
    const trimmed = url.trim()
    if (!trimmed && torrents.files.length === 0) {
      setError(t('addDialog.enterUrl'))
      urlRef.current?.focus()
      return
    }
    const network = networkSpec()
    if (network === null) return

    setBusy(true)
    try {
      const summary = await submitAdd({
        text: trimmed,
        validLinks: links.valid,
        files: torrents.files,
        options: { folder: folder.trim(), priority, paused, network },
      })
      // Nothing queued: stay open with the input intact so the user can fix and retry.
      if (summary.added === 0 && summary.refused === 0 && summary.failures.length > 0) {
        for (const f of summary.failures) onWarn(f.file ? `${f.file}: ${f.error}` : f.error)
        setBusy(false)
        return
      }
      onAdded(summary)
    } catch (e) {
      // A 403 was already toasted by `api`; anything else is ours to report. Staying open keeps the typed URL.
      const message = failureMessage(e)
      if (message) onWarn(message)
      setBusy(false)
    }
  }

  function onKeyDown(e: KeyboardEvent<HTMLDivElement>) {
    if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
      e.preventDefault()
      void submit()
    }
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
        // A .torrent dropped anywhere on the dialog joins the list, not just on the drop zone.
        onDragOver={(e) => {
          if (dragHasFiles(e.dataTransfer)) e.preventDefault()
        }}
        onDrop={(e) => {
          if (!dragHasFiles(e.dataTransfer)) return
          e.preventDefault()
          e.stopPropagation()
          addFiles([...e.dataTransfer.files])
        }}
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
            <LinkIssues
              id={countId}
              valid={links.valid}
              unsupported={links.unsupported}
              onRemove={(text) => setUrl((u) => removeLine(u, text))}
            />
          )}
          <TorrentDropZone
            files={torrents.files}
            rejected={torrents.rejected}
            onFiles={addFiles}
            onRemove={(file) =>
              setTorrents((cur) => ({ files: cur.files.filter((f) => f !== file), rejected: [] }))
            }
          />
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
            <div className="fg fg-prio">
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
