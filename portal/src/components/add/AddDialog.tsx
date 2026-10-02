import { useEffect, useId, useRef, useState, type KeyboardEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { saveDraft, type AddDraft } from '../../lib/addDraft'
import { loadAddPrefs, rememberAdd, type AddPriority } from '../../lib/addPrefs'
import { checkedText, initialChecks, reviewRows, reviewTotals, type ReviewRow } from '../../lib/addReview'
import { submitAdd, type AddSummary } from '../../lib/addSubmit'
import { api, ApiError, failureMessage } from '../../lib/api'
import { BOOT } from '../../lib/boot'
import { removeLine, summarizeLinks } from '../../lib/links'
import { dragHasFiles, mergeTorrents, type TorrentMerge } from '../../lib/torrentFiles'
import { Icon } from '../ui/Icon'
import { Modal } from '../ui/Modal'
import { AddExtras, NO_EXTRAS, type AddExtrasValue } from './AddExtras'
import { NetworkChoice, useAddNetwork } from './AddNetwork'
import { AddOptions } from './AddOptions'
import { AddReview, ReviewFoot } from './AddReview'
import { setChecks, submitKeys, visibleRows, type ReviewFilter } from './addHelpers'
import { FolderPicker, folderLabel } from './FolderPicker'
import { LinkIssues } from './LinkIssues'
import { TorrentDropZone } from './TorrentDropZone'

export { AdapterLine } from './AdapterLine'

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

/**
 * Add download: paste links or drop .torrent files, choose where and how, then — when there are
 * links — review what the server made of each one before anything is queued.
 */
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
  const [priority, setPriority] = useState<AddPriority>(initialDraft?.priority ?? prefs.priority)
  const [paused, setPaused] = useState(initialDraft?.paused ?? false)
  /** Set while the review step shows: paste → review → add. */
  const [review, setReview] = useState<Review | null>(null)
  const [filter, setFilter] = useState<ReviewFilter>('all')
  const [extras, setExtras] = useState<AddExtrasValue>(NO_EXTRAS)
  const [more, setMore] = useState(false)
  const network = useAddNetwork()
  const [busy, setBusy] = useState(false)
  /** What the busy button is doing: checking links for the review, or adding. */
  const [phase, setPhase] = useState<'check' | 'add'>('add')
  const [picking, setPicking] = useState(false)
  const [home, setHome] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const urlRef = useRef<HTMLTextAreaElement>(null)
  const wrapRef = useRef<HTMLDivElement>(null)
  const id = useId()
  const links = summarizeLinks(url)
  const count = links.valid + torrents.files.length

  // Each step starts with focus in its first field: the links, or the first line to tick.
  const reviewing = review != null
  useEffect(() => {
    if (!reviewing) return void urlRef.current?.focus()
    wrapRef.current?.querySelector<HTMLElement>('.add-rv input:not(:disabled), .add-rv button')?.focus()
  }, [reviewing])

  // Kept as typed: an expired session reloads the page to sign in, and would otherwise lose it.
  useEffect(() => {
    saveDraft({ url, folder, priority, paused })
  }, [url, folder, priority, paused])

  /** Null when the choice is unusable, having already warned; callers must not warn again. */
  function networkSpec(): string | null {
    const spec = network.spec()
    if (spec === null) onWarn(t('addDialog.pickInterface'))
    return spec
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
      setFilter('all')
      setReview({ rows, checked: initialChecks(rows), freeBytes: result.freeBytes })
      setBusy(false)
    } catch (e) {
      setBusy(false)
      // A refused folder or an expired session was reported by `api`: stay put.
      if (e instanceof ApiError && (e.kind === 'refused' || e.kind === 'auth')) return
      // The server is checking other links (429): say so and let the user retry, not skip the review.
      if (e instanceof ApiError && e.status === 429) return void onWarn(e.message)
      // An older server without the review step (404), a timeout: never block the add itself.
      return send(trimmed, links.valid)
    }
  }

  async function send(text: string, validLinks: number) {
    if (text === '' && torrents.files.length === 0) return
    const spec = networkSpec()
    if (spec === null || !extras.valid) return

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
          network: spec,
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
      // A 403 was already reported by `api`; anything else is ours. Staying open keeps the links.
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
  const submitCount = totals ? totals.count + torrents.files.length : count
  const pristine = url.trim() === '' && torrents.files.length === 0
  const titleId = `${id}-title`
  const errorId = `${id}-error`
  const countId = `${id}-count`
  const footId = `${id}-foot`
  const moreId = `${id}-more`

  const toggleRow = (index: number, on: boolean) =>
    setReview((r) => (r ? { ...r, checked: setChecks(r.checked, r.rows.filter((x) => x.index === index), on) } : r))
  const checkShown = (on: boolean) =>
    setReview((r) => (r ? { ...r, checked: setChecks(r.checked, visibleRows(r.rows, filter), on) } : r))

  const primaryLabel = busy
    ? phase === 'add'
      ? t('addDialog.adding')
      : t('workflow.add.checking')
    : !review && links.valid > 0
      ? t('adding.continue')
      : submitCount > 1
        ? t('addDialog.submitCount', { count: submitCount })
        : t('addDialog.submit')

  return (
    <>
      <Modal
        labelledBy={titleId}
        onClose={onClose}
        // The folder picker stacks its own sheet on top; while it is open, Tab and Escape are its.
        trap={!picking}
        // A stray click outside must not throw away pasted links.
        scrimCloses={pristine}
        width={review ? 760 : 600}
        className="add"
      >
        <div
          ref={wrapRef}
          className="add-wrap"
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
          {review && totals ? (
            <>
              <div className="sheet-h add-h add-h-rv">
                <h2 className="h2" id={titleId}>
                  {t('adding.reviewTitle', { count: review.rows.length })}
                </h2>
                <span className="sp" />
                <span className="small muted">
                  {t('adding.selectedOf', { n: totals.count, total: review.rows.length })}
                </span>
                <button type="button" className="btn sm ghost" onClick={() => checkShown(true)}>
                  {t('adding.selectAll')}
                </button>
                <button type="button" className="btn sm ghost" onClick={() => checkShown(false)}>
                  {t('adding.selectNone')}
                </button>
              </div>
              <div className="sheet-b">
                <AddReview
                  rows={review.rows}
                  checked={review.checked}
                  onToggle={toggleRow}
                  filter={filter}
                  onFilter={setFilter}
                  torrentNames={torrents.files.map((f) => f.name)}
                  footId={footId}
                />
              </div>
            </>
          ) : (
            <>
              <div className="sheet-h add-h">
                <h2 className="h2" id={titleId}>
                  {t('addDialog.title')}
                </h2>
                <span className="sp" />
                {links.valid > 0 && <span className="pill nodot">{t('adding.step', { step: 1, total: 2 })}</span>}
              </div>
              <div className="sheet-b">
                <div className="col add-url">
                  <div className="row add-url-h">
                    <label className="lbl" htmlFor={`${id}-url`}>
                      {t('addDialog.urlLabel')}
                    </label>
                    {pasted && <span className="pill acc nodot">{t('workflow.add.pasted')}</span>}
                  </div>
                  <div className={`field area${error ? ' invalid' : ''}`}>
                    <textarea
                      id={`${id}-url`}
                      ref={urlRef}
                      value={url}
                      spellCheck={false}
                      autoCapitalize="off"
                      autoCorrect="off"
                      onChange={(e) => {
                        setUrl(e.target.value)
                        setError(null)
                      }}
                      placeholder={t('addDialog.urlPlaceholder')}
                      aria-invalid={error ? true : undefined}
                      aria-describedby={`${error ? errorId : countId} ${id}-hint`}
                    />
                  </div>
                  <p className="help" id={`${id}-hint`}>
                    {t('addDialog.urlHint')} {t('addDialog.submitShortcut')}
                  </p>
                  {error && (
                    <p className="err-text" id={errorId} role="alert">
                      {error}
                    </p>
                  )}
                </div>
                {!error && (
                  <LinkIssues
                    id={countId}
                    lines={links.lines}
                    valid={links.valid}
                    unsupported={links.unsupported}
                    onRemove={(text) => setUrl((u) => removeLine(u, text))}
                  />
                )}
                <TorrentDropZone
                  files={torrents.files}
                  rejected={torrents.rejected}
                  onFiles={addFiles}
                  onRemove={(file) => setTorrents((cur) => ({ files: cur.files.filter((f) => f !== file), rejected: [] }))}
                />
                <AddOptions
                  folder={folder}
                  home={home}
                  recent={prefs.recent}
                  onFolder={setFolder}
                  onBrowse={() => setPicking(true)}
                  priority={priority}
                  onPriority={setPriority}
                  paused={paused}
                  onPaused={setPaused}
                />
                <div className="col add-more">
                  <button
                    type="button"
                    className="btn ghost sm add-more-btn"
                    aria-expanded={more}
                    aria-controls={moreId}
                    onClick={() => setMore((m) => !m)}
                  >
                    <Icon name={more ? 'chevronDown' : 'chevronRight'} size="s" />
                    {t('adding.moreOptions')}
                  </button>
                  {/* Hidden, not unmounted: a chosen start time survives folding the section. */}
                  <div id={moreId} className="well add-more-body" hidden={!more}>
                    <AddExtras value={extras} onChange={setExtras} />
                    <NetworkChoice network={network} />
                  </div>
                </div>
              </div>
            </>
          )}

          <div className="sheet-f">
            {review && totals && (
              <>
                <button type="button" className="btn ghost" onClick={() => setReview(null)}>
                  <Icon name="chevronLeft" />
                  {t('workflow.add.back')}
                </button>
                <ReviewFoot id={footId} totals={totals} freeBytes={review.freeBytes} folderLabel={shownFolder} />
              </>
            )}
            <span className="sp" />
            <button type="button" className="btn" onClick={onClose}>
              {t('common.cancel')}
            </button>
            <button
              type="button"
              className="btn pri"
              onClick={() => void submit()}
              disabled={busy || !extras.valid || (review != null && submitCount === 0)}
            >
              {primaryLabel}
              {!busy && (
                <span className="kbd add-kbd" aria-hidden="true">
                  {submitKeys()}
                </span>
              )}
            </button>
          </div>
        </div>
      </Modal>
      {picking && (
        <FolderPicker
          initialPath={folder}
          canCreate={!BOOT.readOnly}
          onWarn={onWarn}
          onClose={() => setPicking(false)}
          onPick={(path, listing) => {
            setHome(listing.home)
            // The configured default is stored blank, so changing it later still applies here.
            setFolder(path === listing.defaultFolder ? '' : path)
            setPicking(false)
          }}
        />
      )}
    </>
  )
}
