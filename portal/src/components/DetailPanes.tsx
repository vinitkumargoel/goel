import type { ReactNode } from 'react'
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

/** A long value that ellipsises, with a copy button pinned beside it. */
function CopyableValue({ value, onCopy }: { value: string; onCopy: (text: string) => void }) {
  return (
    <>
      <span className="ell">{value}</span>
      <button className="cbtn" onClick={() => onCopy(value)} aria-label="Copy">
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
  const t = detail.row
  const percent = pct(t.progress)
  const eta = fmtEta(t.etaSeconds)
  const isTorrent = t.kind === 'torrent'

  return (
    <>
      <div className="dpw">
        <div className="dptop">
          <span className="dpct">{percent.toFixed(0)}%</span>
          <span className="dpsz">
            {fmtSize(t.doneBytes)} / {fmtSize(t.totalBytes)}
          </span>
        </div>
        <Bar fraction={t.progress} />
      </div>

      {t.statusToken === 'failed' && t.error && (
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
          ⚠ {t.error}
        </div>
      )}

      <KV k="Save path">
        <CopyableValue value={detail.savePath} onCopy={onCopy} />
      </KV>
      <KV k="Downloaded">{fmtSize(t.doneBytes)}</KV>
      {isTorrent && (
        <>
          <KV k="Uploaded">{fmtSize(t.upBytes)}</KV>
          <KV k="Share ratio">{t.ratio.toFixed(2)}</KV>
        </>
      )}
      {eta && <KV k="ETA">{eta}</KV>}
      <KV k="Speed">
        {/* Non-breaking spaces, not literal ones: JSX collapses runs of
            whitespace, which would push the two rates together. */}
        ↓ {fmtSpeed(t.downSpeed)}
        {isTorrent && <>{'  '}↑ {fmtSpeed(t.upSpeed)}</>}
      </KV>
      <KV k="Protocol">{kindLabel(t.kind)}</KV>
      <KV k="Source">
        <CopyableValue value={t.source} onCopy={onCopy} />
      </KV>
    </>
  )
}

const MONO = { fontFamily: 'ui-monospace, monospace', fontSize: 11 } as const

export function DetailsPane({ detail }: { detail: TaskDetail }) {
  const t = detail.row

  if (t.kind === 'torrent') {
    return (
      <>
        <KV k="Info hash">
          <span className="ell" style={{ ...MONO, maxWidth: 150 }}>
            {detail.infoHash ?? '—'}
          </span>
        </KV>
        <KV k="Seeds">{t.seeds ?? '—'}</KV>
        <KV k="Peers">{t.conns}</KV>
        <KV k="Sequential">{detail.sequential ? 'On' : 'Off'}</KV>
        {detail.trackers.length > 0 && (
          <>
            <div className="slbl">Trackers</div>
            {detail.trackers.map((tr) => (
              <div className="kv" key={tr.url}>
                <span
                  className="k"
                  style={{ ...MONO, maxWidth: 160, overflow: 'hidden', textOverflow: 'ellipsis' }}
                >
                  {tr.host || tr.url}
                </span>
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
      <KV k="Server">{detail.server ?? '—'}</KV>
      <KV k="MIME">{detail.mimeType ?? '—'}</KV>
      <KV k="Connections">{t.conns}</KV>
      <KV k="Segments">{t.conns}</KV>
    </>
  )
}

export function ProgressPane({ detail }: { detail: TaskDetail }) {
  const t = detail.row

  if (t.kind === 'torrent' && detail.pieces.length > 0) {
    return (
      <>
        <div className="slbl">Piece map · {detail.pieces.length} buckets</div>
        <div className="pieces">
          {detail.pieces.map((v, i) => (
            // Index keys are correct here: the bucket list is a fixed-length
            // positional array, not a reorderable collection.
            <span key={i} className={v >= 1 ? 'f' : v > 0 ? 'p' : ''} />
          ))}
        </div>
      </>
    )
  }

  if (detail.connections.length > 0) {
    return (
      <>
        <div className="slbl">{detail.connections.length} segments</div>
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
          <span className="dpct">{pct(t.progress).toFixed(0)}%</span>
        </div>
        <Bar fraction={t.progress} />
      </div>
      <p className="fhint">Live piece/segment data appears here while the transfer runs.</p>
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
  const t = detail.row

  // A single-file transfer has no per-file rows, so the task stands in — no checkbox, since skipping
  // the only file would just be a slower way of pausing.
  if (detail.files.length === 0) {
    return (
      <>
        <div className="frow">
          <div className="fchk on">
            <CheckIcon />
          </div>
          <div className="finfo">
            <div className="fname">{t.name}</div>
            <div className="fbar">
              <i style={{ width: `${pct(t.progress)}%` }} />
            </div>
          </div>
          <span className="fsz">{fmtSize(t.totalBytes)}</span>
        </div>
        <p className="fhint" style={{ marginTop: 12 }}>
          Single-file download.
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
              {f.priority}
            </span>
          </div>
        )
      })}
    </>
  )
}

export function PeersPane({ detail }: { detail: TaskDetail }) {
  const t = detail.row
  const rows = detail.connections

  if (t.kind === 'torrent') {
    return (
      <>
        <div className="slbl">
          {t.seeds ?? 0} seeds · {t.conns} peers
        </div>
        <div className="crow h">
          <span>Peer</span>
          <span className="cd">↓</span>
          <span className="cu">↑</span>
        </div>
        {rows.length === 0 && <p className="fhint">No connected peers right now.</p>}
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
      <div className="slbl">{t.conns} connections</div>
      <div className="crow h">
        <span>Segment</span>
        <span className="cd">↓</span>
        <span className="cu">range</span>
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
      {rows.length === 0 && <p className="fhint">Segment data appears while downloading.</p>}
    </>
  )
}
