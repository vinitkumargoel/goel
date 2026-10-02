import { useId, useState, type FormEvent } from 'react'
import { useTranslation } from 'react-i18next'
import type { QueueControls } from '../../hooks/useQueueControls'
import { isAnnounceURL, parseTrackers } from '../../lib/trackers'
import type { TrackerRow } from '../../lib/types'
import { Icon } from '../ui/Icon'

/**
 * A torrent's trackers under Network. With write access each one can be edited or removed and new
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
    <div className="sect">
      <div className="sect-h">
        <span className="eyebrow">{t('sheet.net.trackersCount', { count: trackers.length })}</span>
        <span className="sp" />
        {queue && !adding && (
          <button type="button" className="btn sm" onClick={() => setAdding(true)}>
            <Icon name="plus" size="s" />
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
      {trackers.length === 0 && <p className="small muted">{t('trackers.none')}</p>}
      <div className="dtrk">
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
      </div>
    </div>
  )
}

function trackerPill(state: TrackerRow['state']): string {
  switch (state) {
    case 'working':
      return 'pill good nodot'
    case 'updating':
      return 'pill warn nodot'
    case 'error':
      return 'pill bad nodot'
    default:
      return 'pill nodot'
  }
}

/** An erroring tracker is red with its own message under it; counts show when the tracker sent them. */
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
  const hasCounts = tr.seeds != null || tr.leeches != null
  const counts = { seeds: tr.seeds ?? '—', leeches: tr.leeches ?? '—' }
  const host = tr.host || tr.url
  return (
    <div className={`dtrk-row${error ? ' bad' : ''}`}>
      <div className="dtrk-main">
        {/* Tracker status text and message come from the tracker itself. */}
        <span className={trackerPill(tr.state)}>{error ? t('queue.trackerError') : tr.status}</span>
        <span className="mono ell dtrk-url" title={tr.url}>
          {host}
        </span>
        {hasCounts && (
          <span className="mono small faint" title={t('queue.trackerCounts', counts)}>
            <span aria-hidden="true">{t('sheet.net.trackerCountsShort', counts)}</span>
            <span className="sr-only">{t('queue.trackerCounts', counts)}</span>
          </span>
        )}
        {onEdit && onRemove && (
          <span className="dtrk-acts">
            <button type="button" className="btn ghost sm" onClick={onEdit} aria-label={t('trackers.editNamed', { host })}>
              {t('queue.edit')}
            </button>
            <button
              type="button"
              className="ibtn sm"
              onClick={onRemove}
              aria-label={t('trackers.removeNamed', { host })}
              title={t('trackers.removeNamed', { host })}
            >
              <Icon name="trash" size="s" />
            </button>
          </span>
        )}
      </div>
      {error && tr.message && <span className="small badc dtrk-msg">{tr.message}</span>}
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
    try {
      await onSubmit(urls)
    } finally {
      setBusy(false)
    }
  }
  return (
    <form className="dtrk-form" data-local-escape onSubmit={(e) => void submit(e)}>
      <label className="sr-only" htmlFor={id}>
        {t('trackers.addLabel')}
      </label>
      <div className={`field area${invalid.length ? ' invalid' : ''}`}>
        <textarea
          id={id}
          className="mono"
          rows={3}
          value={text}
          autoFocus
          placeholder="udp://tracker.example.org:1337/announce"
          aria-invalid={invalid.length > 0}
          aria-describedby={`${id}-hint`}
          onChange={(e) => setText(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Escape') {
              e.stopPropagation()
              onCancel()
            }
          }}
        />
      </div>
      <p className={`small${invalid.length ? ' badc' : ' muted'}`} id={`${id}-hint`}>
        {invalid.length ? t('trackers.invalid', { url: invalid[0] }) : t('trackers.addHint')}
      </p>
      <div className="dtrk-btns">
        <button type="button" className="btn ghost sm" onClick={onCancel}>
          {t('common.cancel')}
        </button>
        <button type="submit" className="btn pri sm" disabled={busy || urls.length === 0 || invalid.length > 0}>
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
  const id = useId()
  const [text, setText] = useState(url)
  const [busy, setBusy] = useState(false)
  const valid = isAnnounceURL(text)
  const changed = text.trim() !== url
  const submit = async (e: FormEvent) => {
    e.preventDefault()
    if (!valid || !changed || busy) return
    setBusy(true)
    try {
      await onSubmit(text.trim())
    } finally {
      setBusy(false)
    }
  }
  return (
    <form className="dtrk-form" data-local-escape onSubmit={(e) => void submit(e)}>
      <div className={`field sm${valid ? '' : ' invalid'}`}>
        <input
          className="mono"
          value={text}
          autoFocus
          aria-label={t('trackers.editLabel')}
          aria-invalid={!valid}
          aria-describedby={valid ? undefined : `${id}-err`}
          onChange={(e) => setText(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Escape') {
              e.stopPropagation()
              onCancel()
            }
          }}
        />
      </div>
      {!valid && (
        <p className="small badc" id={`${id}-err`}>
          {t('trackers.invalid', { url: text.trim() || '—' })}
        </p>
      )}
      <div className="dtrk-btns">
        <button type="button" className="btn ghost sm" onClick={onCancel}>
          {t('common.cancel')}
        </button>
        <button type="submit" className="btn pri sm" disabled={busy || !valid || !changed}>
          {t('common.save')}
        </button>
      </div>
    </form>
  )
}
