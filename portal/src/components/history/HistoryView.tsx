import { useCallback, useEffect, useId, useMemo, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { api, failureMessage, historyFileURL } from '../../lib/api'
import { copyText } from '../../lib/clipboard'
import { fmtSize } from '../../lib/format'
import { filterHistory, groupHistory, historyCSV, type KindFilter } from '../../lib/historyTools'
import { saveToDevice } from '../../lib/saveFile'
import { KIND_LABEL } from '../../lib/taskKind'
import type { HistoryRow, TaskKind } from '../../lib/types'
import { FolderPicker } from '../add/FolderPicker'
import { ConfirmDialog, type ConfirmRequest } from '../dialogs/ConfirmDialog'
import { Icon } from '../ui/Icon'
import { Menu, type MenuEntry, type MenuState } from '../ui/Menu'
import { HistoryItem } from './HistoryItem'
import { countOlderThan, csvFileName, DAY, saveFile } from './historyParts'
import { HistorySummary } from './HistorySummary'

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

/**
 * Everything finished, as a timeline grouped by day: artwork cards with their actions in place,
 * search and protocol chips, CSV export, "Clear older than…", select mode for bulk removal, and a
 * month summary beside it on a wide screen.
 */
export function HistoryView({ canWrite, onReadd, onRemoved, onWarn, onToast, refreshKey }: HistoryViewProps) {
  const { t } = useTranslation()
  const [rows, setRows] = useState<HistoryRow[]>([])
  const [state, setState] = useState<LoadState>('loading')
  const [query, setQuery] = useState('')
  const [kind, setKind] = useState<KindFilter>('all')
  const [selecting, setSelecting] = useState(false)
  const [selected, setSelected] = useState<ReadonlySet<string>>(new Set())
  const [confirm, setConfirm] = useState<ConfirmRequest | null>(null)
  const [readdTarget, setReaddTarget] = useState<HistoryRow | null>(null)
  /** `owner` is 'clear' for the Clear menu, an entry's id for its row menu. */
  const [menu, setMenu] = useState<(MenuState & { owner: string }) | null>(null)
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

  // A download finishing elsewhere lands here without a manual reload. The first key is the mount's.
  const firstKey = useRef(refreshKey)
  useEffect(() => {
    if (refreshKey === firstKey.current) return
    firstKey.current = undefined
    void load(true)
  }, [refreshKey, load])

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
  const allShownSelected = shown.length > 0 && shown.every((r) => selected.has(r.id))
  const report = (e: unknown) => {
    const message = failureMessage(e)
    if (message) onWarn(message)
  }

  async function remove(entryId: string) {
    try {
      await api.removeHistory(entryId)
      onRemoved()
      await load(true)
    } catch (e) {
      report(e)
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
      report(e)
    }
  }

  function askClear(days: number | null) {
    // Said before it happens: "Everything" is one request that empties the whole history.
    const count = countOlderThan(rows, days)
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
          .catch(report)
      },
    })
  }

  async function readdTo(entry: HistoryRow, folder: string) {
    try {
      await api.add({ url: entry.source, folder })
      onToast?.(t('toast.readded'))
    } catch (e) {
      report(e)
    }
  }

  async function copyLink(source: string) {
    if (await copyText(source)) onToast?.(t('toast.copied'))
    else onWarn(t('toast.copyFailed'))
  }

  function exportCSV() {
    saveFile(csvFileName(), historyCSV(shown), 'text/csv;charset=utf-8')
    onToast?.(t('history.exported', { count: shown.length }))
  }

  const openClearMenu = (el: HTMLElement) => {
    const r = el.getBoundingClientRect()
    setMenu({
      owner: 'clear',
      x: r.left,
      y: r.bottom + 4,
      label: t('historyBulk.clearOlder'),
      entries: [
        { heading: t('historyBulk.clearOlder') },
        { key: '7', label: t('historyBulk.clear7'), icon: <Icon name="clock" />, action: () => askClear(7) },
        { key: '30', label: t('historyBulk.clear30'), icon: <Icon name="cal" />, action: () => askClear(30) },
        { separator: true },
        { key: 'all', label: t('historyBulk.clearAll'), icon: <Icon name="trash" />, danger: true, action: () => askClear(null) },
      ],
    })
  }

  const openRowMenu = (entry: HistoryRow, at: { x: number; y: number }) => {
    const entries: MenuEntry[] = []
    if (canWrite) {
      entries.push(
        { key: 'readd', label: t('history.readd'), icon: <Icon name="retry" />, action: () => void onReadd(entry.source) },
        { key: 'readdTo', label: t('historyBulk.readdTo'), icon: <Icon name="folderPlus" />, action: () => setReaddTarget(entry) },
      )
    }
    entries.push(
      { key: 'save', label: t('history.saveHint'), icon: <Icon name="download" />, action: () => saveToDevice(historyFileURL(entry.id), entry.name) },
      { key: 'copy', label: t('common.copyLink'), icon: <Icon name="link" />, action: () => void copyLink(entry.source) },
    )
    if (canWrite) {
      entries.push(
        { separator: true },
        { key: 'remove', label: t('pages.history.remove'), icon: <Icon name="trash" />, danger: true, action: () => void remove(entry.id) },
      )
    }
    setMenu({ ...at, owner: entry.id, entries, label: entry.name })
  }

  const leaveSelect = () => {
    setSelecting(false)
    setSelected(new Set())
  }

  const ready = state === 'ready'
  const tools = ready && rows.length > 0

  return (
    <div className="hist">
      <header className="hist-head">
        <div className="hist-title">
          <h1 className="h1">{t('common.history')}</h1>
          <p className="small muted">{t('history.subtitle')}</p>
        </div>
        {tools && (
          <div className="hist-hacts">
            <button type="button" className="btn sm" onClick={exportCSV} disabled={shown.length === 0}>
              <Icon name="upload" size="s" />
              {t('history.exportCsv')}
            </button>
            {canWrite && (
              <button
                type="button"
                className="btn sm"
                aria-pressed={selecting}
                onClick={() => (selecting ? leaveSelect() : setSelecting(true))}
              >
                <Icon name={selecting ? 'check' : 'list'} size="s" />
                {selecting ? t('workflow.library.done') : t('pages.history.select')}
              </button>
            )}
            {canWrite && (
              <button
                type="button"
                className="btn sm dang"
                aria-haspopup="menu"
                aria-expanded={menu?.owner === 'clear'}
                onClick={(e) => openClearMenu(e.currentTarget)}
              >
                <Icon name="trash" size="s" />
                {t('historyBulk.clear')}
              </button>
            )}
          </div>
        )}
      </header>

      {tools && (
        <div className="hist-tools" role="search">
          <div className="field hist-search">
            <Icon name="search" size="s" className="faint" />
            <input
              type="search"
              value={query}
              onChange={(e) => setQuery(e.target.value)}
              placeholder={t('pages.history.searchPlaceholder')}
              aria-label={t('history.search')}
            />
          </div>
          <div className="hist-chips" role="group" aria-label={t('history.protocol')}>
            <button type="button" className="chip" aria-pressed={kind === 'all'} onClick={() => setKind('all')}>
              {t('history.allProtocols')}
            </button>
            {KINDS.map((k) => (
              <button key={k} type="button" className="chip" aria-pressed={kind === k} onClick={() => setKind(k)}>
                {KIND_LABEL[k]}
              </button>
            ))}
          </div>
        </div>
      )}

      {selecting && ready && shown.length > 0 && (
        <div className="hist-bulk" role="group" aria-label={t('pages.history.selection')}>
          <label className="row small hist-all">
            <input
              type="checkbox"
              className="check"
              checked={allShownSelected}
              onChange={(e) =>
                setSelected(e.target.checked ? new Set([...selected, ...shown.map((r) => r.id)]) : new Set())
              }
            />
            {t('historyBulk.selectAll')}
          </label>
          <span className="sp" />
          {selected.size > 0 && (
            <button type="button" className="btn sm dang" onClick={() => void removeSelected()}>
              <Icon name="trash" size="s" />
              {t('historyBulk.removeSelected', { count: selected.size })}
            </button>
          )}
        </div>
      )}

      <div className="hist-body">
        <div className="hist-main">
          {ready && shown.length > 0 && (
            <p className="small muted hist-sum">
              {t('history.summary', { count: shown.length, size: fmtSize(shownBytes) })}
            </p>
          )}
          {state === 'loading' && (
            <p className="empty" role="status">
              {t('common.loading')}
            </p>
          )}
          {state === 'error' && (
            <div className="empty" role="alert">
              <Icon name="alert" size="xl" />
              <p>{t('history.loadError')}</p>
              <button type="button" className="btn" onClick={() => void load()}>
                <Icon name="retry" size="s" />
                {t('common.retry')}
              </button>
            </div>
          )}
          {ready && rows.length === 0 && (
            <div className="empty">
              <Icon name="history" size="xl" className="faint" />
              <p className="h3">{t('history.empty')}</p>
              <p className="small muted">{t('pages.history.emptyHint')}</p>
            </div>
          )}
          {ready && rows.length > 0 && shown.length === 0 && (
            <p className="empty" role="status">
              {t('history.noMatch')}
            </p>
          )}
          {ready &&
            groups.map((g) => (
              <section key={g.group} className="hist-group" aria-labelledby={`${id}-${g.group}`}>
                <h2 className="eyebrow hist-gh" id={`${id}-${g.group}`}>
                  {t(`history.groups.${g.group}`)}
                  <span className="hist-gn" aria-hidden="true">
                    {' · '}
                    {g.rows.length}
                  </span>
                </h2>
                <ul className="hist-list">
                  {g.rows.map((e) => (
                    <HistoryItem
                      key={e.id}
                      entry={e}
                      group={g.group}
                      canWrite={canWrite}
                      onReadd={(source) => void onReadd(source)}
                      onRemove={(entryId) => void remove(entryId)}
                      onCopy={(source) => void copyLink(source)}
                      onMore={openRowMenu}
                      selected={selecting ? selected.has(e.id) : undefined}
                      onSelect={selecting ? toggle : undefined}
                    />
                  ))}
                </ul>
              </section>
            ))}
        </div>
        {tools && <HistorySummary rows={rows} titleId={`${id}-month`} />}
      </div>

      <Menu menu={menu} onClose={() => setMenu(null)} />
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
