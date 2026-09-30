import { useCallback, useEffect, useId, useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { api, failureMessage } from '../lib/api'
import { filterHistory, groupHistory, historyCSV, type KindFilter } from '../lib/historyTools'
import { KIND_LABEL } from '../lib/taskKind'
import type { HistoryRow, TaskKind } from '../lib/types'
import { HistoryItem } from './HistoryItem'
import { DownloadIcon, RetryIcon, SearchIcon } from './Icons'

type LoadState = 'loading' | 'ready' | 'error'

interface HistoryViewProps {
  canWrite: boolean
  onReadd: (source: string) => Promise<void>
  onRemoved: () => void
  onWarn: (message: string) => void
  onToast?: (message: string) => void
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

/**
 * Completed and removed downloads, grouped by day, searchable and filterable by protocol. There
 * is deliberately no "Clear all": the server has no endpoint for it, only per-entry removal.
 */
export function HistoryView({ canWrite, onReadd, onRemoved, onWarn, onToast }: HistoryViewProps) {
  const { t } = useTranslation()
  const [rows, setRows] = useState<HistoryRow[]>([])
  const [state, setState] = useState<LoadState>('loading')
  const [query, setQuery] = useState('')
  const [kind, setKind] = useState<KindFilter>('all')
  const id = useId()

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

  const shown = useMemo(() => filterHistory(rows, query, kind), [rows, query, kind])
  const groups = useMemo(() => groupHistory(shown), [shown])

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

  function exportCSV() {
    const stamp = new Date().toISOString().slice(0, 10)
    saveFile(`goel-history-${stamp}.csv`, historyCSV(shown), 'text/csv;charset=utf-8')
    onToast?.(t('history.exported', { count: shown.length }))
  }

  return (
    <div className="view">
      <div className="pad">
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
          </div>
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
                      onReadd={(source) => void onReadd(source)}
                      onRemove={(entryId) => void remove(entryId)}
                    />
                  ))}
                </ul>
              </section>
            ))}
        </div>
      </div>
    </div>
  )
}
