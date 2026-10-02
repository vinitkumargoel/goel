import { useId, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { streamURL } from '../../lib/api'
import { extension } from '../../lib/fileTree'
import { fmtClock, fmtSize } from '../../lib/format'
import type { TaskRow } from '../../lib/types'
import { Icon } from '../ui/Icon'
import { Bar } from '../ui/Meter'
import { Modal } from '../ui/Modal'

/** Containers no mainstream browser plays: skip the doomed attempt and offer the way out at once. */
const UNPLAYABLE = new Set(['mkv', 'avi', 'wmv', 'flv', 'm2ts', 'ts', 'mpg', 'mpeg', 'vob', 'rmvb'])

export function canPlayInBrowser(name: string): boolean {
  return !UNPLAYABLE.has(extension(name))
}

interface PlayerDialogProps {
  task: TaskRow
  onClose: () => void
  onCopy: (text: string) => void
}

/**
 * Plays a download in the page. While it is still arriving, the bar in the controls shows how much
 * exists on disk — with "download in order" that is the playable part; seeking past it waits.
 */
export function PlayerDialog({ task, onClose, onCopy }: PlayerDialogProps) {
  const { t } = useTranslation()
  const titleId = useId()
  const [failed, setFailed] = useState(() => !canPlayInBrowser(task.name))

  const ext = extension(task.name)
  const total = task.totalBytes ?? 0
  const available = total > 0 ? Math.min(1, task.doneBytes / total) : 0
  const complete = task.statusToken === 'completed' || task.statusToken === 'seeding'
  const link = new URL(streamURL(task.id), location.href).toString()
  const buffered =
    !complete && total > 0 ? (
      <span className="pl-buf">
        <Bar value={available} thin label={t('player.buffered')} />
        <span className="tiny muted">
          {t('player.bufferedOf', { done: fmtSize(task.doneBytes), total: fmtSize(total) })}
        </span>
      </span>
    ) : null

  return (
    <Modal labelledBy={titleId} onClose={onClose} width={920} className="player">
      <div className="sheet-h pl-h">
        <div className="pl-title">
          <span className="eyebrow">{t('sheet.player.nowPlaying')}</span>
          <h2 id={titleId} className="h3 ell" title={task.name}>
            {task.name}
          </h2>
        </div>
        <button type="button" className="btn sm" onClick={onClose}>
          {t('sheet.player.done')}
        </button>
      </div>
      {failed ? (
        <div className="sheet-b pl-cant" role="status">
          <div className="pl-cant-h">
            <Icon name="film" size="l" className="warnc" />
            <b>{t('player.cantPlay', { ext: ext ? `.${ext}` : t('player.thisFile') })}</b>
          </div>
          <p className="small muted">{t('player.cantPlayHint')}</p>
          <div className="pl-acts">
            {complete && (
              <a className="btn pri sm" href={streamURL(task.id, true)} download={task.name}>
                <Icon name="download" />
                {t('menu.saveToDevice')}
              </a>
            )}
            <button type="button" className="btn sm" onClick={() => onCopy(link)}>
              <Icon name="link" />
              {t('player.copyLink')}
            </button>
            <a className="btn sm" href={streamURL(task.id)} target="_blank" rel="noopener noreferrer">
              <Icon name="ext" />
              {t('sheet.player.openTab')}
            </a>
          </div>
          {buffered}
        </div>
      ) : (
        <Video src={streamURL(task.id)} onError={() => setFailed(true)} buffered={buffered} />
      )}
    </Modal>
  )
}

/** The video and its glass controls: play, position, sound, full screen, and what is on disk. */
function Video({ src, onError, buffered }: { src: string; onError: () => void; buffered: React.ReactNode }) {
  const { t } = useTranslation()
  const video = useRef<HTMLVideoElement>(null)
  const stage = useRef<HTMLDivElement>(null)
  const [playing, setPlaying] = useState(false)
  const [muted, setMuted] = useState(false)
  const [time, setTime] = useState(0)
  const [duration, setDuration] = useState(0)

  const toggle = () => {
    const v = video.current
    if (!v) return
    if (v.paused) void v.play()?.catch(() => {})
    else v.pause()
  }
  const known = Number.isFinite(duration) && duration > 0

  return (
    <div className="pl-stage" ref={stage}>
      <video
        ref={video}
        className="pl-video"
        src={src}
        autoPlay
        playsInline
        preload="metadata"
        onClick={toggle}
        onError={onError}
        onPlay={() => setPlaying(true)}
        onPause={() => setPlaying(false)}
        onTimeUpdate={(e) => setTime(e.currentTarget.currentTime)}
        onDurationChange={(e) => setDuration(e.currentTarget.duration)}
        onVolumeChange={(e) => setMuted(e.currentTarget.muted)}
      />
      <div className="pl-ctrl">
        <div className="pl-seek mono tiny">
          <span>{fmtClock(time)}</span>
          <input
            type="range"
            min={0}
            max={known ? duration : 0}
            step="any"
            value={Math.min(time, known ? duration : 0)}
            disabled={!known}
            aria-label={t('sheet.player.seek')}
            aria-valuetext={`${fmtClock(time)} / ${known ? fmtClock(duration) : '—'}`}
            onChange={(e) => {
              const v = video.current
              if (v) v.currentTime = Number(e.target.value)
            }}
          />
          <span>{known ? fmtClock(duration) : '—'}</span>
        </div>
        <div className="pl-row">
          <button
            type="button"
            className="ibtn"
            onClick={toggle}
            aria-label={playing ? t('sheet.player.pause') : t('sheet.player.play')}
          >
            <Icon name={playing ? 'pause' : 'play'} />
          </button>
          <button
            type="button"
            className="ibtn"
            aria-pressed={muted}
            aria-label={muted ? t('sheet.player.unmute') : t('sheet.player.mute')}
            onClick={() => {
              const v = video.current
              if (v) v.muted = !v.muted
            }}
          >
            <Icon name={muted ? 'mute' : 'vol'} />
          </button>
          <span className="sp" />
          {buffered}
          <button
            type="button"
            className="ibtn"
            aria-label={t('sheet.player.fullscreen')}
            onClick={() => void stage.current?.requestFullscreen?.().catch(() => {})}
          >
            <Icon name="full" />
          </button>
        </div>
      </div>
    </div>
  )
}
