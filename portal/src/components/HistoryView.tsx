import { useCallback, useEffect, useId, useMemo, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useMediaQuery } from '../hooks/useMediaQuery'
import { api, failureMessage } from '../lib/api'
import { fmtSize } from '../lib/format'
import { filterHistory, groupHistory, historyCSV, type KindFilter } from '../lib/historyTools'
import { KIND_LABEL } from '../lib/taskKind'
import type { HistoryRow, TaskKind } from '../lib/types'
import { ConfirmDialog, type ConfirmRequest } from './ConfirmDialog'
import { FolderPicker } from './FolderPicker'
import { HistoryItem } from './HistoryItem'
import { DownloadIcon, RetryIcon, SearchIcon, TrashIcon } from './Icons'

type LoadState = 'loading' | 'ready' | 'error'

interface HistoryViewProps {
  canWrite: boolean
  onReadd: (source: string) => Promise<void>
  onRemoved: () => void
  onWarn: (message: string) => void
  onToast?: (message: string) => void
  /** Changes whenever a download finishes or leaves the list: the history reloads quietly. */
  refreshKey?: string
}

const KINDS = Object.keys(KIND_LABEL) as TaskKind[]

/** Hands the browser a file to save. A no-op where object URLs are missing (jsdom). */
function saveFile(name: string, text: string, type: string) {
  if (typeof URL.createObjectURL !== 'function') return
  const url = URL.createObjectURL(new Blob([text], { type }))
  const a = document.createElement('a')
  a.href = url
  a.download = name
  a.rel = 'noopener'
  document.body.append(a)
  a.click()
  a.remove()
  setTimeout(() => URL.revokeObjectURL(url), 0)
}

const DAY = 86_400

/**
 * Completed and removed downloads, grouped by day, searchable and filterable by protocol, with
 * bulk removal of ticked rows and "Clear older than…" for housekeeping.
 */
export function HistoryView({ canWrite, onReadd, onRemoved, onWarn, onToast, refreshKey }: HistoryViewProps) {
  const { t } = useTranslation()
  const [rows, setRows] = useState<HistoryRow[]>([])
  const [state, setState] = useState<LoadState>('loading')
  const [query, setQuery] = useState('')
  const [kind, setKind] = useState<KindFilter>('all')
  const id = useId()
  const compact = useMediaQuery('(max-width: 680px)')

  /** `quiet` keeps the current rows on screen, so a reload after a removal doesn't drop focus. */
  const load = useCallback(async (quiet = false) => {
    if (!quiet) setState('loading')
    try {
      setRows(await api.history())
      setState('ready')
    } catch {
      setState('error')
    }
  }, [])

  useEffect(() => {
    void load()
  }, [load])

  // A download finishing elsewhere lands here without a manual reload. The first key is the mount's.
  const firstKey = useRef(refreshKey)
  useEffect(() => {
    if (refreshKey === firstKey.current) return
    firstKey.current = undefined
    void load(true)
  }, [refreshKey, load])

  const [selected, setSelected] = useState<ReadonlySet<string>>(new Set())
  const [confirm, setConfirm] = useState<ConfirmRequest | null>(null)
  const [readdTarget, setReaddTarget] = useState<HistoryRow | null>(null)
  // Ticks survive a reload only for rows that still exist.
  useEffect(() => {
    setSelected((prev) => {
      const ids = new Set(rows.map((r) => r.id))
      const next = new Set([...prev].filter((x) => ids.has(x)))
      return next.size === prev.size ? prev : next
    })
  }, [rows])

  const toggle = useCallback((entryId: string, on: boolean) => {
    setSelected((prev) => {
      const next = new Set(prev)
      if (on) next.add(entryId)
      else next.delete(entryId)
      return next
    })
  }, [])

  const shown = useMemo(() => filterHistory(rows, query, kind), [rows, query, kind])
  const groups = useMemo(() => groupHistory(shown), [shown])
  const shownBytes = useMemo(() => shown.reduce((n, e) => n + (e.totalBytes ?? 0), 0), [shown])

  async function remove(entryId: string) {
    try {
      await api.removeHistory(entryId)
      onRemoved()
      await load(true)
    } catch (e) {
      const message = failureMessage(e)
      if (message) onWarn(message)
    }
  }

  async function removeSelected() {
    const ids = [...selected]
    try {
      await api.removeHistoryMany(ids)
      setSelected(new Set())
      onToast?.(t('historyBulk.removed', { count: ids.length }))
      await load(true)
    } catch (e) {
      const message = failureMessage(e)
      if (message) onWarn(message)
    }
  }

  function askClear(days: number | null) {
    // Said before it happens: "Clear everything" is one request that empties the whole history.
    const cutoff = days == null ? Infinity : Date.now() / 1000 - days * DAY
    const count = rows.filter((r) => r.completedAt < cutoff).length
    if (count === 0) {
      onToast?.(t('historyBulk.clearNothing'))
      return
    }
    setConfirm({
      title: t('historyBulk.clearTitle'),
      body: days == null ? t('historyBulk.clearBodyAll') : t('historyBulk.clearBodyOlder', { days }),
      footnote: t('historyBulk.clearCount', { count }),
      confirmLabel: t('historyBulk.clearN', { count }),
      onConfirm: () => {
        void api
          .clearHistory(days == null ? undefined : days * DAY)
          .then(() => load(true))
          .catch((e: unknown) => {
            const message = failureMessage(e)
            if (message) onWarn(message)
          })
      },
    })
  }

  async function readdTo(entry: HistoryRow, folder: string) {
    try {
      await api.add({ url: entry.source, folder })
      onToast?.(t('toast.readded'))
    } catch (e) {
      const message = failureMessage(e)
      if (message) onWarn(message)
    }
  }

  const allShownSelected = shown.length > 0 && shown.every((r) => selected.has(r.id))

  function exportCSV() {
    const stamp = new Date().toISOString().slice(0, 10)
    saveFile(`goel-history-${stamp}.csv`, historyCSV(shown), 'text/csv;charset=utf-8')
    onToast?.(t('history.exported', { count: shown.length }))
  }

  return (
    <div className="view">
      <div className="pad hpad">
        <div className="ph">{t('common.history')}</div>
        <div className="psub">{t('history.subtitle')}</div>

        {state === 'ready' && rows.length > 0 && (
          <div className="htools" role="search">
            <div className="search hsearch">
              <SearchIcon aria-hidden="true" />
              <input
                type="search"
                value={query}
                onChange={(e) => setQuery(e.target.value)}
                placeholder={t('history.search')}
                aria-label={t('history.search')}
              />
            </div>
            <label className="sr-only" htmlFor={`${id}-kind`}>
              {t('history.protocol')}
            </label>
            <select
              id={`${id}-kind`}
              className="finput hkind"
              value={kind}
              onChange={(e) => setKind(e.target.value as KindFilter)}
            >
              <option value="all">{t('history.allProtocols')}</option>
              {KINDS.map((k) => (
                <option key={k} value={k}>
                  {KIND_LABEL[k]}
                </option>
              ))}
            </select>
            <button className="mbtn" onClick={exportCSV} disabled={shown.length === 0}>
              <DownloadIcon aria-hidden="true" />
              {t('history.exportCsv')}
            </button>
            {canWrite && (
              <select
                className="finput hkind"
                value=""
                aria-label={t('historyBulk.clearOlder')}
                onChange={(e) => {
                  const v = e.target.value
                  if (v) askClear(v === 'all' ? null : Number(v))
                }}
              >
                <option value="" disabled>
                  {t('historyBulk.clear')}
                </option>
                <optgroup label={t('historyBulk.clearOlder')}>
                  <option value="7">{t('historyBulk.clear7')}</option>
                  <option value="30">{t('historyBulk.clear30')}</option>
                </optgroup>
                <option value="all">{t('historyBulk.clearAll')}</option>
              </select>
            )}
          </div>
        )}
        {canWrite && state === 'ready' && shown.length > 0 && (
          <div className="hbulk">
            <label className="hbulk-all">
              <input
                type="checkbox"
                checked={allShownSelected}
                onChange={(e) =>
                  setSelected(e.target.checked ? new Set([...selected, ...shown.map((r) => r.id)]) : new Set())
                }
              />
              {t('historyBulk.selectAll')}
            </label>
            {selected.size > 0 && (
              <button className="mbtn danger" onClick={() => void removeSelected()}>
                <TrashIcon aria-hidden="true" />
                {t('historyBulk.removeSelected', { count: selected.size })}
              </button>
            )}
          </div>
        )}
        {state === 'ready' && shown.length > 0 && (
          <p className="hsum">{t('history.summary', { count: shown.length, size: fmtSize(shownBytes) })}</p>
        )}

        <div className="card hcard">
          {state === 'loading' && (
            <p className="fhint" role="status" style={{ padding: 8 }}>
              {t('common.loading')}
            </p>
          )}
          {state === 'error' && (
            <div className="herr" role="alert">
              <p className="fhint">{t('history.loadError')}</p>
              <button className="mbtn" onClick={() => void load()}>
                <RetryIcon />
                {t('common.retry')}
              </button>
            </div>
          )}
          {state === 'ready' && rows.length === 0 && (
            <p className="fhint" style={{ padding: 14 }}>
              {t('history.empty')}
            </p>
          )}
          {state === 'ready' && rows.length > 0 && shown.length === 0 && (
            <p className="fhint" role="status" style={{ padding: 14 }}>
              {t('history.noMatch')}
            </p>
          )}
          {state === 'ready' &&
            groups.map((g) => (
              <section key={g.group} className="hgroup" aria-labelledby={`${id}-${g.group}`}>
                <h3 className="hghead" id={`${id}-${g.group}`}>
                  {t(`history.groups.${g.group}`)}
                </h3>
                <ul className="hlist">
                  {g.rows.map((e) => (
                    <HistoryItem
                      key={e.id}
                      entry={e}
                      canWrite={canWrite}
                      compact={compact}
                      onReadd={(source) => void onReadd(source)}
                      onRemove={(entryId) => void remove(entryId)}
                      selected={canWrite ? selected.has(e.id) : undefined}
                      onSelect={canWrite ? toggle : undefined}
                      onReaddTo={canWrite ? setReaddTarget : undefined}
                    />
                  ))}
                </ul>
              </section>
            ))}
        </div>
      </div>
      {readdTarget && (
        <FolderPicker
          initialPath=""
          canCreate={canWrite}
          onWarn={onWarn}
          onClose={() => setReaddTarget(null)}
          onPick={(path) => {
            const entry = readdTarget
            setReaddTarget(null)
            void readdTo(entry, path)
          }}
        />
      )}
      <ConfirmDialog request={confirm} onClose={() => setConfirm(null)} />
    </div>
  )
}
