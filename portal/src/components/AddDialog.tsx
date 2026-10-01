import { useEffect, useId, useRef, useState, type KeyboardEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { useDialogFocus } from '../hooks/useDialogFocus'
import { useMediaQuery } from '../hooks/useMediaQuery'
import { saveDraft, type AddDraft } from '../lib/addDraft'
import { loadAddPrefs, rememberAdd } from '../lib/addPrefs'
import { checkedText, initialChecks, reviewRows, reviewTotals, type ReviewRow } from '../lib/addReview'
import { submitAdd, type AddSummary } from '../lib/addSubmit'
import { AddExtras, NO_EXTRAS, type AddExtrasValue } from './AddExtras'
import { api, ApiError, failureMessage } from '../lib/api'
import { BOOT } from '../lib/boot'
import { removeLine, summarizeLinks } from '../lib/links'
import { dragHasFiles, mergeTorrents, type TorrentMerge } from '../lib/torrentFiles'
import type { NetworkAdapter, NetworkState } from '../lib/types'
import { AddReview } from './AddReview'
import { FolderPicker, folderLabel } from './FolderPicker'
import { CloseIcon, LinkIcon } from './Icons'
import { LinkIssues } from './LinkIssues'
import { TorrentDropZone } from './TorrentDropZone'

type NetMode = 'auto' | 'split' | 'single'

const PRIORITIES = ['low', 'normal', 'high'] as const

interface AddDialogProps {
  onClose: () => void
  onAdded: (summary: AddSummary) => void
  onWarn: (message: string) => void
  /** Torrent files dropped on the window, which opened the dialog. */
  initialFiles?: readonly File[]
  /** Links and choices typed before a sign-out cut them off, restored after signing back in. */
  initialDraft?: AddDraft | null
  /** Links to start with, e.g. pasted outside any field. */
  initialUrl?: string
  /** `initialUrl` came from the clipboard: the dialog says so. */
  pasted?: boolean
}

interface Review {
  rows: ReviewRow[]
  checked: Set<number>
  freeBytes: number | null
}

export function AddDialog({
  onClose,
  onAdded,
  onWarn,
  initialFiles = [],
  initialDraft = null,
  initialUrl = '',
  pasted = false,
}: AddDialogProps) {
  const { t } = useTranslation()
  // Per browser: the last folder and priority used, and a few recent folders as one-tap chips.
  const [prefs] = useState(loadAddPrefs)
  const [url, setUrl] = useState(initialDraft?.url ?? initialUrl)
  const [torrents, setTorrents] = useState<TorrentMerge>(() => mergeTorrents([], initialFiles))
  const [folder, setFolder] = useState(initialDraft?.folder ?? prefs.folder)
  const [priority, setPriority] = useState<'normal' | 'high' | 'low'>(
    initialDraft?.priority ?? prefs.priority,
  )
  /** Set while the review step shows: paste → review → add. */
  const [review, setReview] = useState<Review | null>(null)
  const [paused, setPaused] = useState(initialDraft?.paused ?? false)
  const [extras, setExtras] = useState<AddExtrasValue>(NO_EXTRAS)
  const [net, setNet] = useState<NetworkState | null>(null)
  const [mode, setMode] = useState<NetMode>('auto')
  const [chosen, setChosen] = useState<string[]>([])
  const [single, setSingle] = useState('')
  const [busy, setBusy] = useState(false)
  /** What the busy button is doing: checking links for the review, or adding. */
  const [phase, setPhase] = useState<'check' | 'add'>('add')
  const [picking, setPicking] = useState(false)
  const [home, setHome] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const urlRef = useRef<HTMLTextAreaElement>(null)
  const modalRef = useRef<HTMLDivElement>(null)
  const id = useId()
  // The folder picker stacks its own modal on top; while it's open, Tab and Escape belong to it.
  useDialogFocus(modalRef, { trap: !picking, onEscape: onClose })
  const links = summarizeLinks(url)
  // A phone gets a full-height sheet: priority as a thumb-sized segmented control, not a select.
  const phone = useMediaQuery('(max-width: 680px)')
  const count = links.valid + torrents.files.length

  // Each step starts with focus in its first field: the links, or the first line to tick.
  const reviewing = review != null
  useEffect(() => {
    if (!reviewing) return void urlRef.current?.focus()
    modalRef.current?.querySelector<HTMLElement>('.rvlist input:not(:disabled), .rvlist button')?.focus()
  }, [reviewing])

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
    if (review) return send(checkedText(review.rows, review.checked), totals?.count ?? 0)
    const trimmed = url.trim()
    if (!trimmed && torrents.files.length === 0) {
      setError(t('addDialog.enterUrl'))
      urlRef.current?.focus()
      return
    }
    if (links.valid === 0) return send(trimmed, 0)
    if (networkSpec() === null) return

    // Step two: ask the server what each line is before queueing anything.
    const lines = links.lines.map((l) => l.text)
    setPhase('check')
    setBusy(true)
    try {
      const result = await api.addPreview({ url: lines.join('\n'), folder: folder.trim() || undefined })
      const rows = reviewRows(lines, result)
      setReview({ rows, checked: initialChecks(rows), freeBytes: result.freeBytes })
      setBusy(false)
    } catch (e) {
      // A refused folder was toasted by `api`; stay put. Anything else — an older server without
      // the review step, a timeout — must not block the add itself.
      if (e instanceof ApiError && (e.kind === 'refused' || e.kind === 'auth')) {
        setBusy(false)
        return
      }
      // The server is checking other links (429): say so and let the user retry, not skip the review.
      if (e instanceof ApiError && e.status === 429) {
        onWarn(e.message)
        setBusy(false)
        return
      }
      setBusy(false)
      return send(trimmed, links.valid)
    }
  }

  async function send(text: string, validLinks: number) {
    if (text === '' && torrents.files.length === 0) return
    const network = networkSpec()
    if (network === null || !extras.valid) return

    setPhase('add')
    setBusy(true)
    try {
      const summary = await submitAdd({
        text,
        validLinks,
        files: torrents.files,
        options: {
          folder: folder.trim(),
          priority,
          paused,
          network,
          sequential: extras.sequential || undefined,
          startAt: extras.startAt ?? undefined,
        },
      })
      // Nothing queued: stay open with the input intact so the user can fix and retry.
      if (summary.added === 0 && summary.refused === 0 && summary.failures.length > 0) {
        for (const f of summary.failures) onWarn(f.file ? `${f.file}: ${f.error}` : f.error)
        setBusy(false)
        return
      }
      rememberAdd(folder.trim(), priority)
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

  const totals = review ? reviewTotals(review.rows, review.checked, review.freeBytes) : null
  const shownFolder = folder ? folderLabel(folder, home) : t('addDialog.defaultFolder')
  const recent = prefs.recent.filter((f) => f !== folder)
  const submitCount = totals ? totals.count + torrents.files.length : count

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
        className="modal add"
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

        {review && totals ? (
          <div className="mbody">
            <div className="flabel">{t('workflow.add.reviewLabel', { count: review.rows.length })}</div>
            <AddReview
              rows={review.rows}
              checked={review.checked}
              onToggle={(index, on) =>
                setReview((r) => {
                  if (!r) return r
                  const checked = new Set(r.checked)
                  if (on) checked.add(index)
                  else checked.delete(index)
                  return { ...r, checked }
                })
              }
              torrentNames={torrents.files.map((f) => f.name)}
              totals={totals}
              freeBytes={review.freeBytes}
              folderLabel={shownFolder}
            />
          </div>
        ) : (
        <div className="mbody">
          <label className="flabel" htmlFor={`${id}-url`}>
            {t('addDialog.urlLabel')}
            {pasted && <span className="chip chip-w pasted">{t('workflow.add.pasted')}</span>}
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
              {recent.length > 0 && (
                <div className="recentf" role="group" aria-label={t('workflow.add.recentFolders')}>
                  <span className="recentl" aria-hidden="true">
                    {t('workflow.add.recent')}
                  </span>
                  {recent.map((f) => (
                    <button key={f} type="button" className="rchip" title={f} onClick={() => setFolder(f)}>
                      {home ? folderLabel(f, home) : shortFolder(f)}
                    </button>
                  ))}
                </div>
              )}
            </div>
            <div className="fg fg-prio">
              {phone ? (
                <>
                  <div className="flabel" id={`${id}-prio`}>
                    {t('addDialog.priority')}
                  </div>
                  <div
                    className="seg prio-seg"
                    role="radiogroup"
                    aria-labelledby={`${id}-prio`}
                    onKeyDown={(e) => {
                      const step = e.key === 'ArrowRight' || e.key === 'ArrowDown' ? 1
                        : e.key === 'ArrowLeft' || e.key === 'ArrowUp' ? -1
                        : 0
                      if (!step) return
                      e.preventDefault()
                      const next = PRIORITIES[(PRIORITIES.indexOf(priority) + step + 3) % 3]!
                      setPriority(next)
                      e.currentTarget.querySelector<HTMLElement>(`[data-p="${next}"]`)?.focus()
                    }}
                  >
                    {PRIORITIES.map((p) => (
                      <button
                        key={p}
                        type="button"
                        role="radio"
                        data-p={p}
                        aria-checked={priority === p}
                        tabIndex={priority === p ? 0 : -1}
                        className={priority === p ? 'on' : undefined}
                        onClick={() => setPriority(p)}
                      >
                        {t(`task.priority.${p}`)}
                      </button>
                    ))}
                  </div>
                </>
              ) : (
                <>
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
                </>
              )}
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
          <AddExtras value={extras} onChange={setExtras} />
        </div>
        )}

        <div className="mfoot">
          {review ? (
            <button className="btn" onClick={() => setReview(null)}>
              {t('workflow.add.back')}
            </button>
          ) : (
            <button className="btn" onClick={onClose}>
              {t('common.cancel')}
            </button>
          )}
          <button
            className="btn primary"
            onClick={submit}
            disabled={busy || (review != null && submitCount === 0)}
          >
            {busy
              ? phase === 'add'
                ? t('addDialog.adding')
                : t('workflow.add.checking')
              : !review && links.valid > 0
                ? t('workflow.add.review')
                : submitCount > 1
                  ? t('addDialog.submitCount', { count: submitCount })
                  : t('addDialog.submit')}
          </button>
        </div>
      </div>
    </>
  )
}

/** A recent folder as a chip: its last two parts, the full path in the title. */
function shortFolder(path: string): string {
  const parts = path.split('/').filter(Boolean)
  return parts.length <= 2 ? parts.join(' / ') || path : `… / ${parts.slice(-2).join(' / ')}`
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
