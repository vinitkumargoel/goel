import { useId } from 'react'
import { useTranslation } from 'react-i18next'
import type { QueueControls } from '../../hooks/useQueueControls'
import { fmtPercent, fmtSpeed } from '../../lib/format'
import { pieceState, piecesHave } from '../../lib/pieces'
import type { ConnRow, TaskDetail } from '../../lib/types'
import { Switch } from '../ui/Controls'
import { Bar } from '../ui/Meter'
import { CopyValue } from './helpers'
import { TrackersSection } from './TrackersSection'

/** Cells per row of the piece map. */
const PIECE_COLS = 40

/**
 * How the work is split: a torrent's hash, swarm, piece map and trackers; an HTTP download's
 * server, segments and the connections fetching them.
 */
export function NetworkPane({
  detail,
  queue,
  onCopy,
}: {
  detail: TaskDetail
  queue?: QueueControls
  onCopy: (text: string) => void
}) {
  const { t } = useTranslation()
  const row = detail.row

  if (row.kind === 'torrent') {
    return (
      <>
        <dl className="facts dfacts">
          <dt>{t('detail.details.infoHash')}</dt>
          <dd className="dcopy">
            {detail.infoHash ? <CopyValue value={detail.infoHash} onCopy={onCopy} /> : '—'}
          </dd>
          <dt>{t('detail.details.seeds')}</dt>
          <dd className="mono">{row.seeds ?? '—'}</dd>
          <dt>{t('detail.details.peers')}</dt>
          <dd>{t('sheet.net.peersConnected', { count: row.conns })}</dd>
          {!(queue && !row.multiFile) && (
            <>
              <dt>{t('detail.details.sequential')}</dt>
              <dd>{detail.sequential ? t('common.on') : t('common.off')}</dd>
            </>
          )}
        </dl>
        {queue && !row.multiFile && (
          <SequentialRow on={detail.sequential} onChange={(on) => queue.setSequential(row.id, on)} />
        )}
        {detail.pieces.length > 0 && <PieceMap pieces={detail.pieces} />}
        <TrackersSection taskId={row.id} trackers={detail.trackers} queue={queue} />
      </>
    )
  }

  const segments = detail.connections
  return (
    <>
      <dl className="facts dfacts">
        <dt>{t('sheet.net.url')}</dt>
        <dd className="dcopy">
          <CopyValue value={row.source} onCopy={onCopy} />
        </dd>
        <dt>{t('detail.details.mime')}</dt>
        <dd className="mono">{detail.mimeType ?? '—'}</dd>
        <dt>{t('detail.details.server')}</dt>
        <dd>{detail.server ?? '—'}</dd>
        <dt>{t('detail.details.connections')}</dt>
        <dd className="mono">{row.conns}</dd>
        <dt>{t('detail.details.segments')}</dt>
        {/* Counted from the segment list: the connection count includes idle sockets. */}
        <dd className="mono">{segments.length || '—'}</dd>
      </dl>
      {segments.length > 0 ? (
        <>
          <Segments segments={segments} />
          <SegmentTable segments={segments} count={row.conns} />
        </>
      ) : (
        <p className="small muted">{t('detail.peers.segmentHint')}</p>
      )}
    </>
  )
}

function SequentialRow({ on, onChange }: { on: boolean; onChange: (on: boolean) => void }) {
  const { t } = useTranslation()
  const id = useId()
  return (
    <div className="dseq">
      <span className="dseq-t">
        <b id={`${id}-t`}>{t('queue.sequential')}</b>
        <span id={`${id}-d`} className="tiny muted">
          {t('queue.sequentialHint')}
        </span>
      </span>
      <Switch checked={on} onChange={onChange} labelledBy={`${id}-t`} describedBy={`${id}-d`} />
    </div>
  )
}

/** One cell per bucket, have/partial/missing — drawn as one SVG so a big torrent stays cheap. */
function PieceMap({ pieces }: { pieces: readonly number[] }) {
  const { t } = useTranslation()
  const total = pieces.length
  const have = piecesHave(pieces)
  const cols = Math.min(PIECE_COLS, total)
  const rows = Math.ceil(total / cols)
  return (
    <div className="sect">
      <div className="sect-h dwrap">
        <span className="eyebrow">{t('sheet.net.pieceMap')}</span>
        <span className="sp" />
        <span className="dlegend" aria-hidden="true">
          <span className="lg acc">{t('detail.progress.have', { count: have })}</span>
          <span className="lg warn">{t('detail.progress.partial')}</span>
          <span className="lg">{t('detail.progress.missing')}</span>
        </span>
      </div>
      <svg
        className="dpm"
        viewBox={`0 0 ${cols * 10} ${rows * 10}`}
        role="img"
        aria-label={t('detail.progress.pieceStrip', { have, total })}
      >
        {pieces.map((p, i) => (
          <rect
            key={i}
            className={pieceState(p)}
            x={(i % cols) * 10}
            y={Math.floor(i / cols) * 10}
            width={8}
            height={8}
            rx={2}
          />
        ))}
      </svg>
    </div>
  )
}

function Segments({ segments }: { segments: readonly ConnRow[] }) {
  const { t } = useTranslation()
  return (
    <div className="sect">
      <div className="sect-h">
        <span className="eyebrow">{t('detail.progress.segments', { count: segments.length })}</span>
      </div>
      <div className="dsegs">
        {segments.map((c, i) => {
          const done = c.progress >= 1
          return (
            <div key={c.id} className="dseg mono tiny">
              <span className="lnum">{i + 1}</span>
              <Bar value={c.progress} tone={done ? 'good' : ''} label={c.label} />
              <span className={done ? 'goodc' : undefined}>{fmtPercent(c.progress)}</span>
            </div>
          )
        })}
      </div>
    </div>
  )
}

/** Only worth a column when multi-adapter aggregation spreads the work over interfaces. */
function hasAdapters(rows: readonly ConnRow[]): boolean {
  return rows.some((c) => c.adapterLabel)
}

function SegmentTable({ segments, count }: { segments: readonly ConnRow[]; count: number }) {
  const { t } = useTranslation()
  const adapters = hasAdapters(segments)
  return (
    <div className="sect">
      <div className="sect-h">
        <span className="eyebrow">{t('detail.peers.connections', { count })}</span>
      </div>
      <table className={`tbl dtbl${adapters ? ' ad' : ''}`}>
        <thead>
          <tr>
            <th scope="col">{t('detail.peers.colSegment')}</th>
            <th scope="col">{t('detail.peers.colRange')}</th>
            <th scope="col" className="r">
              {t('sheet.net.colSpeed')}
            </th>
            {adapters && <th scope="col">{t('queue.colAdapter')}</th>}
          </tr>
        </thead>
        <tbody>
          {segments.map((c) => (
            <tr key={c.id}>
              <td className="mono" title={c.label}>
                {c.label}
              </td>
              <td className="mono muted" title={c.detail}>
                {c.detail}
              </td>
              <td className="r mono acc">{fmtSpeed(c.down)}</td>
              {adapters && <td className="mono">{c.adapterLabel ?? '—'}</td>}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

/** A torrent's swarm: who is connected, how much each has, and what is moving each way. */
export function PeersPane({ detail }: { detail: TaskDetail }) {
  const { t } = useTranslation()
  const row = detail.row
  const peers = detail.connections
  const adapters = hasAdapters(peers)
  return (
    <div className="sect">
      <div className="sect-h">
        <span className="eyebrow">{t('detail.peers.summary', { seeds: row.seeds ?? 0, peers: row.conns })}</span>
      </div>
      {peers.length === 0 ? (
        <p className="small muted">{t('detail.peers.none')}</p>
      ) : (
        <table className={`tbl dtbl dpeers${adapters ? ' ad' : ''}`}>
          <thead>
            <tr>
              <th scope="col">{t('sheet.net.colPeer')}</th>
              <th scope="col" className="r">
                {t('queue.colProgress')}
              </th>
              <th scope="col" className="r">
                ↓
              </th>
              <th scope="col" className="r">
                ↑
              </th>
              {adapters && <th scope="col">{t('queue.colAdapter')}</th>}
            </tr>
          </thead>
          <tbody>
            {peers.map((c) => (
              <tr key={c.id}>
                <td title={`${c.label} ${c.detail}`}>
                  <span className="mono">{c.label}</span>{' '}
                  {/* The client string is what the peer announced about itself. */}
                  <span className="faint">{c.detail === 'peer' ? '—' : c.detail}</span>
                </td>
                <td className="r mono">
                  <span className="sr-only">{t('queue.peerProgress', { peer: c.label })}: </span>
                  {fmtPercent(c.progress)}
                </td>
                <td className={`r mono${c.down > 0 ? ' acc' : ' faint'}`}>{fmtSpeed(c.down)}</td>
                <td className={`r mono${c.up > 0 ? ' upc' : ' faint'}`}>{fmtSpeed(c.up)}</td>
                {adapters && <td className="mono">{c.adapterLabel ?? '—'}</td>}
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  )
}
