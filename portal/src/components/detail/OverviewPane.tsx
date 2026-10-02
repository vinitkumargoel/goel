import { useTranslation } from 'react-i18next'
import type { QueueControls } from '../../hooks/useQueueControls'
import { fmtAbsolute, fmtEta, fmtSize, fmtSpeed, IDLE_RATE, pct } from '../../lib/format'
import { canSave } from '../../lib/saveFile'
import { useSpeedSeries } from '../../lib/speedStore'
import { kindLabel } from '../../lib/taskKind'
import { pillClass, stateTone } from '../../lib/tone'
import type { TaskRow } from '../../lib/types'
import { Icon } from '../ui/Icon'
import { Ring } from '../ui/Meter'
import { SpeedChart } from '../ui/SpeedChart'
import type { PaneProps } from './DetailPanes'
import { anchorAbove, CopyValue, isLive, meterTone, openStream, showsUpload, stateGlyph } from './helpers'

/**
 * The first tab: how far along it is (or how it ended), the last minute's speed, the per-download
 * queue controls, and the facts a person asks about most.
 */
export function OverviewPane({ detail, canWrite, onCopy, onRetry, onMore, onStream, queue }: PaneProps) {
  const { t } = useTranslation()
  const row = detail.row
  const live = isLive(row)
  const isTorrent = row.kind === 'torrent'
  const size = useSizeLine(row)

  return (
    <>
      {row.statusToken === 'metadata' ? (
        <MetadataCard />
      ) : row.statusToken === 'failed' ? (
        <FailureCard row={row} canRetry={canWrite} onRetry={onRetry} onCopy={onCopy} onMore={onMore} />
      ) : canSave(row) ? (
        <FinishedCard row={row} onStream={onStream} />
      ) : (
        <ProgressHero row={row} />
      )}

      {live && <Throughput id={row.id} />}

      <QueueSection row={row} queue={queue} />

      <dl className="facts dfacts">
        {row.statusToken === 'failed' && (
          <>
            <dt>{t('detail.general.downloaded')}</dt>
            <dd className="mono">{size}</dd>
          </>
        )}
        {isTorrent ? (
          <>
            <dt>{t('detail.general.peers')}</dt>
            <dd>{t('detail.general.peersValue', { seeds: row.seeds ?? 0, peers: row.conns })}</dd>
            <dt>{t('detail.general.uploaded')}</dt>
            <dd className="mono">{fmtSize(row.upBytes)}</dd>
            <dt>{t('detail.general.shareRatio')}</dt>
            <dd className="mono">{row.ratio.toFixed(2)}</dd>
          </>
        ) : (
          live && (
            <>
              <dt>{t('detail.details.connections')}</dt>
              <dd className="mono">{row.conns}</dd>
            </>
          )
        )}
        {row.priority && (
          <>
            <dt>{t('sheet.priority')}</dt>
            <dd>{t(`task.priority.${row.priority}`)}</dd>
          </>
        )}
        {row.addedAt > 0 && (
          <>
            <dt>{t('detail.general.added')}</dt>
            <dd>{fmtAbsolute(row.addedAt)}</dd>
          </>
        )}
        {row.completedAt != null && row.completedAt > 0 && (
          <>
            <dt>{t('detail.general.finished')}</dt>
            <dd>{fmtAbsolute(row.completedAt)}</dd>
          </>
        )}
        <dt>{t('detail.general.savePath')}</dt>
        <dd className="dcopy">
          <CopyValue value={detail.savePath} onCopy={onCopy} />
        </dd>
        <dt>{t('detail.general.source')}</dt>
        <dd className="dcopy">
          <CopyValue value={row.source} onCopy={onCopy} />
        </dd>
        <dt>{t('detail.general.protocol')}</dt>
        <dd>{kindLabel(row.kind)}</dd>
      </dl>
    </>
  )
}

function useSizeLine(row: TaskRow): string {
  const { t } = useTranslation()
  return row.totalBytes != null
    ? t('detail.general.sizeOf', { done: fmtSize(row.doneBytes), total: fmtSize(row.totalBytes) })
    : fmtSize(row.doneBytes)
}

/** Big percentage, bytes, live rate and time left, and the arc in the state's colour. */
function ProgressHero({ row }: { row: TaskRow }) {
  const { t } = useTranslation()
  const live = isLive(row)
  const size = useSizeLine(row)
  const tone = meterTone(row)
  const eta = live ? fmtEta(row.etaSeconds) : null
  // Floor, not round: 99.6% must not read 100% while bytes are still owed.
  const percent = row.progress >= 1 ? 100 : Math.floor(pct(row.progress))
  return (
    <div className="hero dhero">
      <div className="dhero-t">
        <span className="bignum">
          {percent}
          <small>%</small>
        </span>
        <span className="mono small muted">{size}</span>
        {live && (
          <span className="dhero-rates mono small">
            <span className="acc">
              <span aria-hidden="true">↓ </span>
              <span className="sr-only">{t('chart.down')} </span>
              <b>{fmtSpeed(row.downSpeed, IDLE_RATE)}</b>
            </span>
            {showsUpload(row) && (
              <span className="upc">
                <span aria-hidden="true">↑ </span>
                <span className="sr-only">{t('chart.up')} </span>
                <b>{fmtSpeed(row.upSpeed, IDLE_RATE)}</b>
              </span>
            )}
            {eta && (
              <>
                <span className="faint" aria-hidden="true">
                  ·
                </span>
                <span>{t('detail.general.left', { eta })}</span>
              </>
            )}
          </span>
        )}
      </div>
      <Ring value={row.progress} size={86} tone={tone} label={t('library.progress')}>
        <span className={`dring-ic ${tone || 'acc'}`}>
          <Icon name={stateGlyph(row.statusToken)} size="l" />
        </span>
      </Ring>
    </div>
  )
}

/** A magnet before its metadata: no size, no files yet — say so instead of 0%. */
function MetadataCard() {
  const { t } = useTranslation()
  return (
    <div className="hero dhero" role="status">
      <div className="dhero-t">
        <b className="h3">{t('sheet.metadata.title')}</b>
        <span className="small muted">{t('sheet.metadata.hint')}</span>
      </div>
      <Ring value={null} size={64}>
        <span className="dring-ic acc">
          <Icon name="magnet" size="l" />
        </span>
      </Ring>
    </div>
  )
}

/** What went wrong, in the daemon's words, and the things that might fix it. */
function FailureCard({
  row,
  canRetry,
  onRetry,
  onCopy,
  onMore,
}: {
  row: TaskRow
  canRetry: boolean
  onRetry: () => void
  onCopy: (text: string) => void
  onMore: (anchor: { x: number; y: number }) => void
}) {
  const { t } = useTranslation()
  // `row.error` is the daemon's own message — passed through, not localized here.
  const reason = row.error || t('detail.general.failedNoReason')
  return (
    <div className="dfail" role="group" aria-label={t('detail.general.failedTitle')}>
      <div className="dfail-h">
        <Icon name="alert" size="l" className="badc" />
        <span className="h3">{t('detail.general.failedTitle')}</span>
      </div>
      <p className="dfail-m">{reason}</p>
      <div className="dfail-acts">
        {canRetry && (
          <button type="button" className="btn pri sm" onClick={onRetry}>
            <Icon name="retry" />
            {t('common.retry')}
          </button>
        )}
        <button
          type="button"
          className="btn sm"
          onClick={() => onCopy([row.name, row.status, reason, row.source].join('\n'))}
        >
          <Icon name="copy" />
          {t('sheet.failed.copyDetails')}
        </button>
        <button
          type="button"
          className="btn sm"
          aria-haspopup="menu"
          onClick={(e) => onMore(anchorAbove(e.currentTarget))}
        >
          {t('detail.moreActions')}
          <Icon name="chevronDown" size="s" />
        </button>
      </div>
    </div>
  )
}

/** How it ended well: the size and when, and Play for anything the browser can stream. */
function FinishedCard({ row, onStream }: { row: TaskRow; onStream?: (row: TaskRow) => void }) {
  const { t } = useTranslation()
  const when = row.completedAt ? fmtAbsolute(row.completedAt) : null
  const size = fmtSize(row.totalBytes ?? row.doneBytes)
  return (
    <div className="dfin">
      {row.streamable && (
        <button
          type="button"
          className="dposter"
          onClick={() => openStream(row, onStream)}
          aria-label={t('sheet.finished.playNamed', { name: row.name })}
        >
          <span className="dposter-play">
            <Icon name="play" size="l" />
          </span>
        </button>
      )}
      <div className="dfin-b">
        <div className="row">
          <span className={pillClass(stateTone(row))}>{row.status}</span>
          <span className="sp" />
          <Icon name={stateGlyph(row.statusToken)} className={row.statusToken === 'seeding' ? 'upc' : 'goodc'} />
        </div>
        <span className="small muted">{when ? t('sheet.finished.summary', { size, when }) : size}</span>
        {row.streamable && (
          <div className="row">
            <button type="button" className="btn pri sm" onClick={() => openStream(row, onStream)}>
              <Icon name="play" />
              {t('sheet.finished.play')}
            </button>
          </div>
        )}
      </div>
    </div>
  )
}

/** The last minute of this download. Subscribes on its own, so a sample redraws only the chart. */
function Throughput({ id }: { id: string }) {
  const { t } = useTranslation()
  const samples = useSpeedSeries(id)
  const peak = samples.reduce((m, s) => Math.max(m, s.down), 0)
  return (
    <div className="sect">
      <div className="sect-h">
        <span className="eyebrow">{t('sheet.throughput')}</span>
        <span className="sp" />
        <span className="mono tiny faint">{t('chart.peak', { rate: fmtSpeed(peak, IDLE_RATE) })}</span>
      </div>
      <SpeedChart samples={samples} />
    </div>
  )
}

/** The per-download controls: cap, place in line, start time, tags. Read-only sessions see values only. */
function QueueSection({ row, queue }: { row: TaskRow; queue?: QueueControls }) {
  const { t } = useTranslation()
  const waiting = row.statusToken === 'queued' || row.statusToken === 'paused'
  const tags = row.tags ?? []
  if (!queue && !row.speedLimit && tags.length === 0 && !row.startAt) return null
  return (
    <div className="sect">
      <div className="sect-h">
        <span className="eyebrow">{t('sheet.queueTitle')}</span>
      </div>
      <dl className="facts dfacts dq">
        <dt>{t('queue.speedLabel')}</dt>
        <dd>
          <span>{row.speedLimit ? fmtSpeed(row.speedLimit) : t('queue.unlimited')}</span>
          {queue && (
            <button type="button" className="btn ghost sm" onClick={() => queue.edit({ kind: 'speed', task: row })}>
              {t('queue.edit')}
            </button>
          )}
        </dd>
        {waiting && (
          <>
            <dt>{t('queue.position')}</dt>
            <dd>
              <span className="mono">{row.queuePosition != null ? `#${row.queuePosition + 1}` : '—'}</span>
              {queue && (
                <>
                  <button type="button" className="btn ghost sm" onClick={() => queue.move([row.id], 'top')}>
                    <Icon name="toTop" size="s" />
                    {t('queue.top')}
                  </button>
                  <button type="button" className="btn ghost sm" onClick={() => queue.move([row.id], 'bottom')}>
                    <Icon name="toBottom" size="s" />
                    {t('queue.bottom')}
                  </button>
                </>
              )}
            </dd>
          </>
        )}
        {(waiting || row.startAt) && (
          <>
            <dt>{t('queue.startLabel')}</dt>
            <dd>
              <span>{row.startAt ? fmtAbsolute(row.startAt) : t('queue.startNow')}</span>
              {queue && (
                <button type="button" className="btn ghost sm" onClick={() => queue.edit({ kind: 'start', task: row })}>
                  {t('queue.edit')}
                </button>
              )}
            </dd>
          </>
        )}
        <dt>{t('queue.tagsLabel')}</dt>
        <dd>
          {tags.length ? (
            <span className="dtags">
              {tags.map((tag) => (
                <span key={tag} className="tag">
                  {tag}
                </span>
              ))}
            </span>
          ) : (
            <span>—</span>
          )}
          {queue && (
            <button type="button" className="btn ghost sm" onClick={() => queue.edit({ kind: 'tags', task: row })}>
              {t('queue.edit')}
            </button>
          )}
        </dd>
      </dl>
    </div>
  )
}
