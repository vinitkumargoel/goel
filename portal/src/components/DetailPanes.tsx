import type { ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { fmtEta, fmtSize, fmtSpeed, pct } from '../lib/format'
import { kindLabel } from '../lib/taskKind'
import type { FilePriority, TaskDetail } from '../lib/types'
import { CheckIcon, CopyIcon } from './Icons'

export type DetailTab = 'general' | 'details' | 'progress' | 'files' | 'peers'

export const DETAIL_TABS: readonly DetailTab[] = [
  'general',
  'details',
  'progress',
  'files',
  'peers',
]

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

function Bar({ fraction, height }: { fraction: number; height?: number }) {
  return (
    <div className="dpbar" style={height ? { height } : undefined}>
      <i style={{ width: `${pct(fraction)}%` }} />
    </div>
  )
}

interface PaneProps {
  detail: TaskDetail
  onCopy: (text: string) => void
}

export function GeneralPane({ detail, onCopy }: PaneProps) {
  const { t } = useTranslation()
  const row = detail.row
  const percent = pct(row.progress)
  const eta = fmtEta(row.etaSeconds)
  const isTorrent = row.kind === 'torrent'

  return (
    <>
      <div className="dpw">
        <div className="dptop">
          <span className="dpct">{percent.toFixed(0)}%</span>
          <span className="dpsz">
            {fmtSize(row.doneBytes)} / {fmtSize(row.totalBytes)}
          </span>
        </div>
        <Bar fraction={row.progress} />
      </div>

      {/* `row.error` is the daemon's own message — passed through, not localized here. */}
      {row.statusToken === 'failed' && row.error && (
        <div
          style={{
            background: 'var(--red-soft)',
            color: 'var(--red)',
            borderRadius: 9,
            padding: 11,
            fontSize: 12,
            marginBottom: 8,
            lineHeight: 1.45,
          }}
        >
          ⚠ {row.error}
        </div>
      )}

      <KV k={t('detail.general.savePath')}>
        <CopyableValue value={detail.savePath} onCopy={onCopy} />
      </KV>
      <KV k={t('detail.general.downloaded')}>{fmtSize(row.doneBytes)}</KV>
      {isTorrent && (
        <>
          <KV k={t('detail.general.uploaded')}>{fmtSize(row.upBytes)}</KV>
          <KV k={t('detail.general.shareRatio')}>{row.ratio.toFixed(2)}</KV>
        </>
      )}
      {eta && <KV k={t('detail.general.eta')}>{eta}</KV>}
      <KV k={t('detail.general.speed')}>
        {/* Non-breaking spaces: JSX collapses literal whitespace, merging the two rates. */}
        ↓ {fmtSpeed(row.downSpeed)}
        {isTorrent && <>{'  '}↑ {fmtSpeed(row.upSpeed)}</>}
      </KV>
      <KV k={t('detail.general.protocol')}>{kindLabel(row.kind)}</KV>
      <KV k={t('detail.general.source')}>
        <CopyableValue value={row.source} onCopy={onCopy} />
      </KV>
    </>
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
      <KV k={t('detail.details.segments')}>{row.conns}</KV>
    </>
  )
}

export function ProgressPane({ detail }: { detail: TaskDetail }) {
  const { t } = useTranslation()
  const row = detail.row

  if (row.kind === 'torrent' && detail.pieces.length > 0) {
    return (
      <>
        <div className="slbl">{t('detail.progress.pieceMap', { count: detail.pieces.length })}</div>
        <div className="pieces">
          {detail.pieces.map((v, i) => (
            // Index keys are correct here: a fixed-length positional array, never reordered.
            <span key={i} className={v >= 1 ? 'f' : v > 0 ? 'p' : ''} />
          ))}
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
            <Bar fraction={c.progress} height={6} />
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
          <div className="fchk on">
            <CheckIcon />
          </div>
          <div className="finfo">
            <div className="fname">{row.name}</div>
            <div className="fbar">
              <i style={{ width: `${pct(row.progress)}%` }} />
            </div>
          </div>
          <span className="fsz">{fmtSize(row.totalBytes)}</span>
        </div>
        <p className="fhint" style={{ marginTop: 12 }}>
          {t('detail.files.singleFile')}
        </p>
      </>
    )
  }

  return (
    <>
      {detail.files.map((f) => {
        const skipped = f.priority === 'skip'
        return (
          <div className="frow" key={f.id}>
            <div
              className={`fchk${skipped ? '' : ' on'}`}
              onClick={canWrite ? () => onToggleFile(f.id, skipped) : undefined}
              style={canWrite ? undefined : { cursor: 'default' }}
            >
              <CheckIcon />
            </div>
            <div className="finfo">
              <div className="fname">{f.name}</div>
              <div className="fbar">
                <i style={{ width: `${pct(f.progress).toFixed(0)}%` }} />
              </div>
            </div>
            <span className="fsz">{fmtSize(f.size)}</span>
            <span
              className={`fprio${f.priority === 'high' ? ' high' : ''}`}
              onClick={canWrite ? () => onCyclePriority(f.id, f.priority) : undefined}
              style={canWrite ? undefined : { cursor: 'default' }}
            >
              {t(`task.priority.${f.priority}`)}
            </span>
          </div>
        )
      })}
    </>
  )
}

export function PeersPane({ detail }: { detail: TaskDetail }) {
  const { t } = useTranslation()
  const row = detail.row
  const rows = detail.connections

  if (row.kind === 'torrent') {
    return (
      <>
        <div className="slbl">
          {t('detail.peers.summary', { seeds: row.seeds ?? 0, peers: row.conns })}
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
          <span className="cu" style={{ color: 'var(--text-faint)' }}>
            {c.detail}
          </span>
        </div>
      ))}
      {rows.length === 0 && <p className="fhint">{t('detail.peers.segmentHint')}</p>}
    </>
  )
}
