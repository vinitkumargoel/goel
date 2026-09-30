import { Fragment, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { fileURL, streamURL, zipURL } from '../lib/api'
import { commonDir, fileLabels, splitTail } from '../lib/names'
import { pieceRuns, piecesHave } from '../lib/pieces'
import { useSpeedSeries } from '../lib/speedStore'
import { SpeedChart } from './SpeedChart'
import { fmtAbsolute, fmtEta, fmtSize, fmtSpeed, IDLE_RATE, pct } from '../lib/format'
import { kindLabel } from '../lib/taskKind'
import type { FilePriority, StatusToken, TaskDetail, TaskKind } from '../lib/types'
import { CheckIcon, CopyIcon, DownloadIcon, FolderIcon, RetryIcon, WarnIcon } from './Icons'

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

export function DetailsPane({ detail }: { detail: TaskDetail }) {
  const { t } = useTranslation()
  const row = detail.row

  if (row.kind === 'torrent') {
    return (
      <>
        <KV k={t('detail.details.infoHash')}>
          <span className="ell" style={{ ...MONO, maxWidth: 150 }}>
            {detail.infoHash ?? '—'}
          </span>
        </KV>
        <KV k={t('detail.details.seeds')}>{row.seeds ?? '—'}</KV>
        <KV k={t('detail.details.peers')}>{row.conns}</KV>
        <KV k={t('detail.details.sequential')}>
          {detail.sequential ? t('common.on') : t('common.off')}
        </KV>
        {detail.trackers.length > 0 && (
          <>
            <div className="slbl">{t('detail.details.trackers')}</div>
            {detail.trackers.map((tr) => (
              <div className="kv" key={tr.url}>
                <span
                  className="k"
                  style={{ ...MONO, maxWidth: 160, overflow: 'hidden', textOverflow: 'ellipsis' }}
                >
                  {tr.host || tr.url}
                </span>
                {/* Tracker status text comes from the tracker itself. */}
                <span className="v">{tr.status}</span>
              </div>
            ))}
          </>
        )}
      </>
    )
  }

  return (
    <>
      <KV k={t('detail.details.server')}>{detail.server ?? '—'}</KV>
      <KV k={t('detail.details.mime')}>{detail.mimeType ?? '—'}</KV>
      <KV k={t('detail.details.connections')}>{row.conns}</KV>
      <KV k={t('detail.details.segments')}>{detail.connections.length || '—'}</KV>
    </>
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
  onToggleFile: (fileId: number, wasSkipped: boolean) => void
  onCyclePriority: (fileId: number, current: FilePriority) => void
}

export function FilesPane({ detail, canWrite, onToggleFile, onCyclePriority }: FilesPaneProps) {
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

  // Season packs repeat one folder on every row, cutting off the part that differs: say it once.
  const shared = commonDir(detail.files.map((f) => f.name))
  const labels = fileLabels(
    detail.files.map((f) => f.name),
    shared,
  )
  const finished = detail.files.filter((f) => f.priority !== 'skip' && f.progress >= 1).length

  return (
    <>
      {(shared || (row.multiFile && finished > 0)) && (
        <div className="fhead">
          {shared && (
            <span className="fdir" title={shared}>
              <FolderIcon aria-hidden="true" />
              <span className="ell">{shared.replace(/\/$/, '').split('/').join(' / ')}</span>
            </span>
          )}
          {row.multiFile && finished > 0 && (
            <a
              className="linkbtn fzip"
              href={zipURL(row.id)}
              download
              title={t('detail.downloadAllHint')}
            >
              {t('detail.files.saveFinished', { count: finished })}
            </a>
          )}
        </div>
      )}
      {detail.files.map((f, i) => {
        const skipped = f.priority === 'skip'
        const { dir, label } = labels[i]!
        const { head, tail } = splitTail(label)
        // A subfolder is named once, above its first file, rather than on every row.
        const heading = dir !== '' && dir !== labels[i - 1]?.dir
        return (
          <Fragment key={f.id}>
            {heading && (
              <div className="fsub" title={shared + dir}>
                <FolderIcon aria-hidden="true" />
                <span className="ell">{dir.split('/').join(' / ')}</span>
              </div>
            )}
            <div className="frow">
              <button
                type="button"
                role="checkbox"
                aria-checked={!skipped}
                aria-label={t('detail.files.download', { name: f.name })}
                className={`fchk${skipped ? '' : ' on'}`}
                disabled={!canWrite}
                onClick={() => onToggleFile(f.id, skipped)}
              >
                <CheckIcon />
              </button>
              <div className="finfo">
                {/* Middle ellipsis: the head truncates, the tail (episode, extension) stays whole. */}
                <div className={`fname${skipped ? ' skipped' : ''}`} title={f.name}>
                  <span className="fhead-t">{head}</span>
                  {tail && <span className="ftail">{tail}</span>}
                </div>
                <div className="fbar">
                  <i style={{ width: `${pct(f.progress).toFixed(0)}%` }} />
                </div>
              </div>
              <span className="fsz">{fmtSize(f.size)}</span>
              <button
                type="button"
                className={`fprio ${f.priority}`}
                disabled={!canWrite}
                aria-label={t('detail.files.priority', {
                  name: f.name,
                  priority: t(`task.priority.${f.priority}`),
                })}
                onClick={() => onCyclePriority(f.id, f.priority)}
              >
                {t(`task.priority.${f.priority}`)}
              </button>
              {!skipped && f.progress >= 1 ? (
                <a
                  className="fdl"
                  href={fileURL(row.id, f.id)}
                  download={baseName(f.name)}
                  aria-label={t('detail.files.save', { name: f.name })}
                  title={t('detail.files.saveHint')}
                >
                  <DownloadIcon />
                </a>
              ) : (
                <span className="fdl-gap" aria-hidden="true" />
              )}
            </div>
          </Fragment>
        )
      })}
    </>
  )
}

function baseName(path: string): string {
  return path.split('/').pop() || path
}

export function PeersPane({ detail }: { detail: TaskDetail }) {
  const { t } = useTranslation()
  const row = detail.row
  const rows = detail.connections

  if (row.kind === 'torrent') {
    return (
      <>
        <div className="slbl">
          {t('detail.peers.summary', {
            seeds: row.seeds ?? 0,
            peers: row.conns,
          })}
        </div>
        <div className="crow h">
          <span>{t('detail.peers.colPeer')}</span>
          <span className="cd">↓</span>
          <span className="cu">↑</span>
        </div>
        {rows.length === 0 && <p className="fhint">{t('detail.peers.none')}</p>}
        {rows.map((c) => (
          <div className="crow" key={c.id}>
            <span className="cip">{c.label}</span>
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
      <div className="crow h">
        <span>{t('detail.peers.colSegment')}</span>
        <span className="cd">↓</span>
        <span className="cu">{t('detail.peers.colRange')}</span>
      </div>
      {rows.map((c) => (
        <div className="crow" key={c.id}>
          <span className="cip">{c.label}</span>
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
