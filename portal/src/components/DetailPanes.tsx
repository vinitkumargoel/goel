import type { ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { streamURL } from '../lib/api'
import { pieceRuns, piecesHave } from '../lib/pieces'
import { useSpeedSeries } from '../lib/speedStore'
import { FilesTree } from './FilesTree'
import { TrackersSection } from './TrackersSection'
import { SpeedChart } from './SpeedChart'
import { fmtAbsolute, fmtEta, fmtSize, fmtSpeed, IDLE_RATE, pct } from '../lib/format'
import { kindLabel } from '../lib/taskKind'
import type { QueueControls } from '../hooks/useQueueControls'
import type { FilePriority, StatusToken, TaskDetail, TaskKind, TaskRow } from '../lib/types'
import { CheckIcon, CopyIcon, DownloadIcon, RetryIcon, WarnIcon } from './Icons'

export type DetailTab = 'general' | 'details' | 'progress' | 'files' | 'peers'

export const DETAIL_TABS: readonly DetailTab[] = [
  'general',
  'details',
  'progress',
  'files',
  'peers',
]

/** The last tab lists HTTP segments or torrent peers; only a torrent's are peers. */
export function tabLabelKey(
  tab: DetailTab,
  kind: TaskKind,
): 'detail.tabs.connections' | `detail.tabs.${DetailTab}` {
  return tab === 'peers' && kind !== 'torrent' ? 'detail.tabs.connections' : `detail.tabs.${tab}`
}

/** Moving now, so live rates and the chart mean something; a finished or failed task shows neither. */
const LIVE: ReadonlySet<StatusToken> = new Set<StatusToken>(['downloading', 'seeding', 'verifying', 'metadata'])

function KV({ k, children }: { k: string; children: ReactNode }) {
  return (
    <div className="kv">
      <span className="k">{k}</span>
      <span className="v">{children}</span>
    </div>
  )
}

function CopyableValue({ value, onCopy }: { value: string; onCopy: (text: string) => void }) {
  const { t } = useTranslation()
  return (
    <>
      <span className="ell">{value}</span>
      <button className="cbtn" onClick={() => onCopy(value)} aria-label={t('common.copy')}>
        <CopyIcon />
      </button>
    </>
  )
}

function Bar({
  fraction,
  height,
  label,
  failed = false,
}: {
  fraction: number
  height?: number
  label?: string
  failed?: boolean
}) {
  const { t } = useTranslation()
  return (
    <div
      className={`dpbar${failed ? ' failed' : ''}`}
      style={height ? { height } : undefined}
      role="progressbar"
      aria-label={label ?? t('library.progress')}
      aria-valuemin={0}
      aria-valuemax={100}
      aria-valuenow={Math.round(pct(fraction))}
    >
      <i style={{ width: `${pct(fraction)}%` }} />
    </div>
  )
}

interface PaneProps {
  detail: TaskDetail
  onCopy: (text: string) => void
  canWrite?: boolean
  onRetry?: () => void
}

export function GeneralPane({ detail, onCopy, canWrite = false, onRetry }: PaneProps) {
  const { t } = useTranslation()
  const row = detail.row
  const percent = pct(row.progress)
  const eta = fmtEta(row.etaSeconds)
  const isTorrent = row.kind === 'torrent'
  const failed = row.statusToken === 'failed'
  const live = LIVE.has(row.statusToken)
  const sizeLine =
    row.totalBytes != null
      ? t('detail.general.sizeOf', { done: fmtSize(row.doneBytes), total: fmtSize(row.totalBytes) })
      : fmtSize(row.doneBytes)

  return (
    <>
      <div className="dpw">
        <div className="dptop">
          <span className="dpct">{percent.toFixed(0)}%</span>
          <span className="dpsz">
            {sizeLine}
            {live && eta && ` · ${t('detail.general.left', { eta })}`}
          </span>
        </div>
        <Bar fraction={row.progress} failed={failed} />
      </div>

      {failed && <FailureCard error={row.error} canRetry={canWrite && onRetry != null} onRetry={onRetry} />}

      {live && (
        <>
          <div className="drates">
            <div className="drate down">
              <span className="drk">{t('chart.down')}</span>
              <b>{fmtSpeed(row.downSpeed, IDLE_RATE)}</b>
            </div>
            <div className="drate up">
              <span className="drk">{t('chart.up')}</span>
              <b>{isTorrent || row.upSpeed > 0 ? fmtSpeed(row.upSpeed, IDLE_RATE) : '—'}</b>
            </div>
          </div>
          <LiveSpeedChart id={row.id} compact />
        </>
      )}

      <KV k={t('detail.general.savePath')}>
        <CopyableValue value={detail.savePath} onCopy={onCopy} />
      </KV>
      {row.addedAt > 0 && <KV k={t('detail.general.added')}>{fmtAbsolute(row.addedAt)}</KV>}
      {row.completedAt != null && row.completedAt > 0 && (
        <KV k={t('detail.general.finished')}>{fmtAbsolute(row.completedAt)}</KV>
      )}
      {isTorrent ? (
        <>
          <KV k={t('detail.general.peers')}>
            {t('detail.general.peersValue', { seeds: row.seeds ?? 0, peers: row.conns })}
          </KV>
          <KV k={t('detail.general.uploaded')}>{fmtSize(row.upBytes)}</KV>
          <KV k={t('detail.general.shareRatio')}>{row.ratio.toFixed(2)}</KV>
        </>
      ) : (
        live && <KV k={t('detail.details.connections')}>{row.conns}</KV>
      )}
      <KV k={t('detail.general.protocol')}>{kindLabel(row.kind)}</KV>
      <KV k={t('detail.general.source')}>
        <CopyableValue value={row.source} onCopy={onCopy} />
      </KV>
    </>
  )
}

/** The native FailureCard's counterpart: what went wrong, and the one action that might fix it. */
function FailureCard({
  error,
  canRetry,
  onRetry,
}: {
  error: string | null
  canRetry: boolean
  onRetry?: () => void
}) {
  const { t } = useTranslation()
  return (
    <div className="dfail" role="group" aria-label={t('detail.general.failedTitle')}>
      <WarnIcon aria-hidden="true" />
      <div className="dfail-body">
        <div className="dfail-t">{t('detail.general.failedTitle')}</div>
        {/* `row.error` is the daemon's own message — passed through, not localized here. */}
        <div className="dfail-m">{error || t('detail.general.failedNoReason')}</div>
      </div>
      {canRetry && (
        <button className="mbtn accent" onClick={onRetry}>
          <RetryIcon />
          {t('common.retry')}
        </button>
      )}
    </div>
  )
}

const MONO = { fontFamily: 'ui-monospace, monospace', fontSize: 11 } as const

export function DetailsPane({ detail, queue }: { detail: TaskDetail; queue?: QueueControls }) {
  const { t } = useTranslation()
  const row = detail.row
  const controls = <QueueSection row={row} queue={queue} />

  if (row.kind === 'torrent') {
    return (
      <>
        {controls}
        <KV k={t('detail.details.infoHash')}>
          <span className="ell" style={{ ...MONO, maxWidth: 150 }}>
            {detail.infoHash ?? '—'}
          </span>
        </KV>
        <KV k={t('detail.details.seeds')}>{row.seeds ?? '—'}</KV>
        <KV k={t('detail.details.peers')}>{row.conns}</KV>
        {queue && !row.multiFile ? (
          <label className="kv qseq">
            <span className="k">
              {t('queue.sequential')}
              <span className="qseq-hint">{t('queue.sequentialHint')}</span>
            </span>
            <input
              type="checkbox"
              role="switch"
              className="tgl"
              checked={detail.sequential}
              onChange={(e) => queue.setSequential(row.id, e.target.checked)}
            />
          </label>
        ) : (
          <KV k={t('detail.details.sequential')}>
            {detail.sequential ? t('common.on') : t('common.off')}
          </KV>
        )}
        <TrackersSection taskId={row.id} trackers={detail.trackers} queue={queue} />
      </>
    )
  }

  return (
    <>
      {controls}
      <KV k={t('detail.details.server')}>{detail.server ?? '—'}</KV>
      <KV k={t('detail.details.mime')}>{detail.mimeType ?? '—'}</KV>
      <KV k={t('detail.details.connections')}>{row.conns}</KV>
      <KV k={t('detail.details.segments')}>{detail.connections.length || '—'}</KV>
    </>
  )
}

/** The per-download controls: cap, place in line, tags, start time. Read-only sessions see values only. */
function QueueSection({ row, queue }: { row: TaskRow; queue?: QueueControls }) {
  const { t } = useTranslation()
  const waiting = row.statusToken === 'queued' || row.statusToken === 'paused'
  const tags = row.tags ?? []
  if (!queue && !row.speedLimit && tags.length === 0 && !row.startAt) return null
  return (
    <div className="qsect">
      <div className="kv">
        <span className="k">{t('queue.speedLabel')}</span>
        <span className="v">
          {row.speedLimit ? fmtSpeed(row.speedLimit) : t('queue.unlimited')}
          {queue && (
            <button type="button" className="linkbtn" onClick={() => queue.edit({ kind: 'speed', task: row })}>
              {t('queue.edit')}
            </button>
          )}
        </span>
      </div>
      {waiting && (
        <div className="kv">
          <span className="k">{t('queue.position')}</span>
          <span className="v">
            {row.queuePosition != null ? `#${row.queuePosition + 1}` : '—'}
            {queue && (
              <>
                <button type="button" className="linkbtn" onClick={() => queue.move([row.id], 'top')}>
                  {t('queue.top')}
                </button>
                <button type="button" className="linkbtn" onClick={() => queue.move([row.id], 'bottom')}>
                  {t('queue.bottom')}
                </button>
              </>
            )}
          </span>
        </div>
      )}
      {(waiting || row.startAt) && (
        <div className="kv">
          <span className="k">{t('queue.startLabel')}</span>
          <span className="v">
            {row.startAt ? fmtAbsolute(row.startAt) : t('queue.startNow')}
            {queue && (
              <button type="button" className="linkbtn" onClick={() => queue.edit({ kind: 'start', task: row })}>
                {t('queue.edit')}
              </button>
            )}
          </span>
        </div>
      )}
      <div className="kv">
        <span className="k">{t('queue.tagsLabel')}</span>
        <span className="v qtags-inline">
          {tags.length ? tags.map((tag) => <span key={tag} className="qtag on">{tag}</span>) : '—'}
          {queue && (
            <button type="button" className="linkbtn" onClick={() => queue.edit({ kind: 'tags', task: row })}>
              {t('queue.edit')}
            </button>
          )}
        </span>
      </div>
    </div>
  )
}

export function ProgressPane({ detail }: { detail: TaskDetail }) {
  return (
    <>
      <LiveSpeedChart id={detail.row.id} />
      <ProgressBody detail={detail} />
    </>
  )
}

/** Subscribes on its own, so a sample redraws the chart and not the panel around it. */
function LiveSpeedChart({ id, compact = false }: { id: string; compact?: boolean }) {
  return <SpeedChart samples={useSpeedSeries(id)} compact={compact} />
}

function ProgressBody({ detail }: { detail: TaskDetail }) {
  const { t } = useTranslation()
  const row = detail.row

  if (row.kind === 'torrent' && detail.pieces.length > 0) {
    const total = detail.pieces.length
    const have = piecesHave(detail.pieces)
    return (
      <>
        <div className="slbl">{t('detail.progress.pieceMap', { count: total })}</div>
        {/* One strip, one column per bucket (runs merged): the standard piece bar. A grid of
            720 cells overflowed the panel. */}
        <svg
          className="pstrip"
          viewBox={`0 0 ${total} 1`}
          preserveAspectRatio="none"
          role="img"
          aria-label={t('detail.progress.pieceStrip', { have, total })}
        >
          {pieceRuns(detail.pieces).map((r) =>
            r.state === 'missing' ? null : (
              <rect
                key={r.start}
                className={`ps-${r.state}`}
                x={r.start}
                y={0}
                width={r.length}
                height={1}
              />
            ),
          )}
        </svg>
        <div className="plegend" aria-hidden="true">
          <span>
            <i className="ps-have" /> {t('detail.progress.have', { count: have })}
          </span>
          <span>
            <i className="ps-partial" /> {t('detail.progress.partial')}
          </span>
          <span>
            <i className="ps-missing" /> {t('detail.progress.missing')}
          </span>
        </div>
      </>
    )
  }

  if (detail.connections.length > 0) {
    return (
      <>
        <div className="slbl">
          {t('detail.progress.segments', { count: detail.connections.length })}
        </div>
        {detail.connections.map((c) => (
          <div key={c.id} style={{ marginBottom: 9 }}>
            <div
              style={{
                display: 'flex',
                justifyContent: 'space-between',
                fontSize: 11,
                color: 'var(--text-dim)',
                marginBottom: 4,
              }}
            >
              <span>{c.label}</span>
              <span>{pct(c.progress).toFixed(0)}%</span>
            </div>
            <Bar fraction={c.progress} height={6} label={c.label} />
          </div>
        ))}
      </>
    )
  }

  return (
    <>
      <div className="dpw">
        <div className="dptop">
          <span className="dpct">{pct(row.progress).toFixed(0)}%</span>
        </div>
        <Bar fraction={row.progress} />
      </div>
      <p className="fhint">{t('detail.progress.hint')}</p>
    </>
  )
}

interface FilesPaneProps {
  detail: TaskDetail
  canWrite: boolean
  onSetFiles: (fileIds: readonly number[], priority: FilePriority) => Promise<void>
  onCyclePriority: (fileId: number, current: FilePriority) => void
}

export function FilesPane({ detail, canWrite, onSetFiles, onCyclePriority }: FilesPaneProps) {
  const { t } = useTranslation()
  const row = detail.row

  if (detail.files.length === 0) {
    return (
      <>
        <div className="frow">
          <div className="fchk on" aria-hidden="true">
            <CheckIcon />
          </div>
          <div className="finfo">
            <div className="fname">{row.name}</div>
            <div className="fbar">
              <i style={{ width: `${pct(row.progress)}%` }} />
            </div>
          </div>
          <span className="fsz">{fmtSize(row.totalBytes)}</span>
          <span aria-hidden="true" />
          {row.statusToken === 'completed' || row.statusToken === 'seeding' ? (
            <a
              className="fdl"
              href={streamURL(row.id, true)}
              download={row.name}
              aria-label={t('detail.files.save', { name: row.name })}
              title={t('detail.files.saveHint')}
            >
              <DownloadIcon />
            </a>
          ) : (
            <span className="fdl-gap" aria-hidden="true" />
          )}
        </div>
        <p className="fhint" style={{ marginTop: 12 }}>
          {t('detail.files.singleFile')}
        </p>
      </>
    )
  }

  return (
    <FilesTree
      detail={detail}
      canWrite={canWrite}
      onSetFiles={onSetFiles}
      onCyclePriority={onCyclePriority}
    />
  )
}

export function PeersPane({ detail }: { detail: TaskDetail }) {
  const { t } = useTranslation()
  const row = detail.row
  const rows = detail.connections
  // Only worth a column when multi-adapter aggregation is spreading peers over interfaces.
  const adapters = rows.some((c) => c.adapterLabel)

  if (row.kind === 'torrent') {
    return (
      <>
        <div className="slbl">
          {t('detail.peers.summary', {
            seeds: row.seeds ?? 0,
            peers: row.conns,
          })}
        </div>
        <div className={`crow peers h${adapters ? ' ad' : ''}`}>
          <span>{t('detail.peers.colPeer')}</span>
          <span>{t('queue.colClient')}</span>
          <span>{t('queue.colProgress')}</span>
          {adapters && <span>{t('queue.colAdapter')}</span>}
          <span className="cd">↓</span>
          <span className="cu">↑</span>
        </div>
        {rows.length === 0 && <p className="fhint">{t('detail.peers.none')}</p>}
        {rows.map((c) => (
          <div className={`crow peers${adapters ? ' ad' : ''}`} key={c.id}>
            <span className="cip" title={c.label}>{c.label}</span>
            {/* The client string is what the peer announced about itself. */}
            <span className="ccl" title={c.detail}>{c.detail === 'peer' ? '—' : c.detail}</span>
            <span className="cpg" title={`${pct(c.progress).toFixed(0)}%`}>
              <Bar fraction={c.progress} height={4} label={t('queue.peerProgress', { peer: c.label })} />
            </span>
            {adapters && <span className="cad">{c.adapterLabel ?? '—'}</span>}
            <span className="cd">{fmtSpeed(c.down)}</span>
            <span className="cu">{fmtSpeed(c.up)}</span>
          </div>
        ))}
      </>
    )
  }

  return (
    <>
      <div className="slbl">{t('detail.peers.connections', { count: row.conns })}</div>
      <div className={`crow h${adapters ? ' segad' : ''}`}>
        <span>{t('detail.peers.colSegment')}</span>
        {adapters && <span>{t('queue.colAdapter')}</span>}
        <span className="cd">↓</span>
        <span className="cu">{t('detail.peers.colRange')}</span>
      </div>
      {rows.map((c) => (
        <div className={`crow${adapters ? ' segad' : ''}`} key={c.id}>
          <span className="cip">{c.label}</span>
          {adapters && <span className="cad">{c.adapterLabel ?? '—'}</span>}
          <span className="cd">{fmtSpeed(c.down)}</span>
          <span className="cu" style={{ color: 'var(--text-dim)' }}>
            {c.detail}
          </span>
        </div>
      ))}
      {rows.length === 0 && <p className="fhint">{t('detail.peers.segmentHint')}</p>}
    </>
  )
}
