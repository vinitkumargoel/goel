import { useId, useState, type FormEvent } from 'react'
import { useTranslation } from 'react-i18next'
import type { QueueControls } from '../hooks/useQueueControls'
import { isAnnounceURL, parseTrackers } from '../lib/trackers'
import type { TrackerRow } from '../lib/types'
import { PlusIcon, TrashIcon } from './Icons'

const MONO = { fontFamily: 'ui-monospace, monospace', fontSize: 11 } as const

/**
 * The Details tab's tracker list. With write access each tracker can be edited or removed and new
 * ones added (several at once, pasted); read-only sessions see the list only.
 */
export function TrackersSection({
  taskId,
  trackers,
  queue,
}: {
  taskId: string
  trackers: readonly TrackerRow[]
  queue?: QueueControls
}) {
  const { t } = useTranslation()
  const [adding, setAdding] = useState(false)
  const [editing, setEditing] = useState<string | null>(null)

  if (trackers.length === 0 && !queue) return null
  return (
    <>
      <div className="slbl trk-head">
        {t('detail.details.trackers')}
        {queue && !adding && (
          <button type="button" className="linkbtn trk-add" onClick={() => setAdding(true)}>
            <PlusIcon aria-hidden="true" />
            {t('trackers.add')}
          </button>
        )}
      </div>
      {adding && queue && (
        <AddTrackers
          onCancel={() => setAdding(false)}
          onSubmit={async (urls) => {
            if (await queue.editTrackers({ id: taskId, add: urls })) setAdding(false)
          }}
        />
      )}
      {trackers.length === 0 && <p className="fhint">{t('trackers.none')}</p>}
      {trackers.map((tr) =>
        editing === tr.url && queue ? (
          <EditTracker
            key={tr.url}
            url={tr.url}
            onCancel={() => setEditing(null)}
            onSubmit={async (next) => {
              if (await queue.editTrackers({ id: taskId, edit: { old: tr.url, new: next } })) setEditing(null)
            }}
          />
        ) : (
          <TrackerLine
            key={tr.url}
            tracker={tr}
            onEdit={queue ? () => setEditing(tr.url) : undefined}
            onRemove={queue ? () => void queue.editTrackers({ id: taskId, remove: [tr.url] }) : undefined}
          />
        ),
      )}
    </>
  )
}

/** Error is red with the tracker's own message under it; counts show when the tracker sent them. */
function TrackerLine({
  tracker: tr,
  onEdit,
  onRemove,
}: {
  tracker: TrackerRow
  onEdit?: () => void
  onRemove?: () => void
}) {
  const { t } = useTranslation()
  const error = tr.state === 'error'
  const counts =
    tr.seeds != null || tr.leeches != null
      ? t('queue.trackerCounts', { seeds: tr.seeds ?? '—', leeches: tr.leeches ?? '—' })
      : null
  const host = tr.host || tr.url
  return (
    <div className={`trow${error ? ' bad' : ''}`}>
      <span className="trow-host" style={MONO} title={tr.url}>
        {host}
      </span>
      {/* Tracker status text and message come from the tracker itself. */}
      <span className="trow-st">{error ? t('queue.trackerError') : tr.status}</span>
      {(error && tr.message) || counts || onEdit ? (
        <span className="trow-sub">
          <span>
            {error && tr.message ? tr.message : null}
            {error && tr.message && counts ? ' · ' : null}
            {counts}
          </span>
          {onEdit && onRemove && (
            <span className="trow-acts">
              <button type="button" className="linkbtn" onClick={onEdit} aria-label={t('trackers.editNamed', { host })}>
                {t('queue.edit')}
              </button>
              <button
                type="button"
                className="trow-rm"
                onClick={onRemove}
                aria-label={t('trackers.removeNamed', { host })}
                title={t('trackers.removeNamed', { host })}
              >
                <TrashIcon aria-hidden="true" />
              </button>
            </span>
          )}
        </span>
      ) : null}
    </div>
  )
}

function AddTrackers({ onCancel, onSubmit }: { onCancel: () => void; onSubmit: (urls: string[]) => Promise<void> }) {
  const { t } = useTranslation()
  const id = useId()
  const [text, setText] = useState('')
  const [busy, setBusy] = useState(false)
  const { urls, invalid } = parseTrackers(text)
  const submit = async (e: FormEvent) => {
    e.preventDefault()
    if (urls.length === 0 || invalid.length > 0 || busy) return
    setBusy(true)
    await onSubmit(urls)
    setBusy(false)
  }
  return (
    <form className="trk-form" onSubmit={(e) => void submit(e)}>
      <label className="sr-only" htmlFor={id}>
        {t('trackers.addLabel')}
      </label>
      <textarea
        id={id}
        className="finput"
        rows={3}
        value={text}
        autoFocus
        placeholder="udp://tracker.example.org:1337/announce"
        aria-invalid={invalid.length > 0}
        aria-describedby={`${id}-hint`}
        onChange={(e) => setText(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === 'Escape') onCancel()
        }}
      />
      <p className={`fhint${invalid.length ? ' trk-bad' : ''}`} id={`${id}-hint`}>
        {invalid.length ? t('trackers.invalid', { url: invalid[0] }) : t('trackers.addHint')}
      </p>
      <div className="trk-btns">
        <button type="button" className="btn ghost" onClick={onCancel}>
          {t('common.cancel')}
        </button>
        <button type="submit" className="btn primary" disabled={busy || urls.length === 0 || invalid.length > 0}>
          {t('trackers.addCount', { count: urls.length })}
        </button>
      </div>
    </form>
  )
}

function EditTracker({
  url,
  onCancel,
  onSubmit,
}: {
  url: string
  onCancel: () => void
  onSubmit: (next: string) => Promise<void>
}) {
  const { t } = useTranslation()
  const [text, setText] = useState(url)
  const [busy, setBusy] = useState(false)
  const valid = isAnnounceURL(text)
  const changed = text.trim() !== url
  const submit = async (e: FormEvent) => {
    e.preventDefault()
    if (!valid || !changed || busy) return
    setBusy(true)
    await onSubmit(text.trim())
    setBusy(false)
  }
  return (
    <form className="trk-form trk-edit" onSubmit={(e) => void submit(e)}>
      <input
        className="finput"
        value={text}
        autoFocus
        aria-label={t('trackers.editLabel')}
        aria-invalid={!valid}
        onChange={(e) => setText(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === 'Escape') onCancel()
        }}
      />
      {!valid && <p className="fhint trk-bad">{t('trackers.invalid', { url: text.trim() || '—' })}</p>}
      <div className="trk-btns">
        <button type="button" className="btn ghost" onClick={onCancel}>
          {t('common.cancel')}
        </button>
        <button type="submit" className="btn primary" disabled={busy || !valid || !changed}>
          {t('common.save')}
        </button>
      </div>
    </form>
  )
}
