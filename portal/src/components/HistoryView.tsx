import { useCallback, useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { api } from '../lib/api'
import { fmtSize, fmtWhen } from '../lib/format'
import { fileType, kindLabel } from '../lib/taskKind'
import type { HistoryRow } from '../lib/types'
import { FileTypeIcon, RetryIcon, TrashIcon } from './Icons'

type LoadState = 'loading' | 'ready' | 'error'

interface HistoryViewProps {
  canWrite: boolean
  onReadd: (source: string) => Promise<void>
  onRemoved: () => void
}

export function HistoryView({ canWrite, onReadd, onRemoved }: HistoryViewProps) {
  const { t } = useTranslation()
  const [rows, setRows] = useState<HistoryRow[]>([])
  const [state, setState] = useState<LoadState>('loading')

  const load = useCallback(async () => {
    setState('loading')
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

  async function remove(id: string) {
    try {
      await api.removeHistory(id)
      onRemoved()
      await load()
    } catch {
      // Already surfaced by the api layer.
    }
  }

  return (
    <div className="view">
      <div className="pad">
        <div className="ph">{t('common.history')}</div>
        <div className="psub">{t('history.subtitle')}</div>

        <div className="card">
          {state === 'loading' && (
            <p className="fhint" style={{ padding: 8 }}>
              {t('common.loading')}
            </p>
          )}
          {state === 'error' && (
            <p className="fhint" style={{ padding: 14 }}>
              {t('history.loadError')}
            </p>
          )}
          {state === 'ready' && rows.length === 0 && (
            <p className="fhint" style={{ padding: 14 }}>
              {t('history.empty')}
            </p>
          )}
          {state === 'ready' &&
            rows.map((e) => {
              const type = fileType({ name: e.name, kind: e.kind, statusToken: '' })
              // `savePath` includes the file name, so the folder is the second-to-last component, not the last.
              const parts = e.savePath.split('/').filter(Boolean)
              const folder = parts.length >= 2 ? parts[parts.length - 2]! : ''
              return (
                <div className="hrow" key={e.id}>
                  <div className={`hic ft-${type}`}>
                    <FileTypeIcon type={type} />
                  </div>
                  <div style={{ minWidth: 0 }}>
                    <div className="ntext">{e.name}</div>
                    <div style={{ fontSize: 11, color: 'var(--text-faint)' }}>
                      {kindLabel(e.kind)} · {fmtWhen(e.completedAt)}
                    </div>
                  </div>
                  <div className="c r" style={{ color: 'var(--text-dim)' }}>
                    {fmtSize(e.totalBytes)}
                  </div>
                  <div
                    className="c r hide-sm"
                    style={{ color: 'var(--text-faint)', fontSize: 11.5 }}
                  >
                    {folder}
                  </div>
                  <div style={{ display: 'flex', gap: 6 }}>
                    {canWrite && (
                      <>
                        <button className="mbtn" onClick={() => void onReadd(e.source)}>
                          <RetryIcon />
                          {t('history.readd')}
                        </button>
                        <button
                          className="mbtn danger"
                          onClick={() => void remove(e.id)}
                          aria-label={t('common.remove')}
                        >
                          <TrashIcon />
                        </button>
                      </>
                    )}
                  </div>
                </div>
              )
            })}
        </div>
      </div>
    </div>
  )
}
