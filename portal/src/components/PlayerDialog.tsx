import { useId, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useDialogFocus } from '../hooks/useDialogFocus'
import { streamURL } from '../lib/api'
import { extension } from '../lib/fileTree'
import { fmtSize, pct } from '../lib/format'
import type { TaskRow } from '../lib/types'
import { CloseIcon, DownloadIcon, LinkIcon } from './Icons'

/** Containers no mainstream browser plays: skip the doomed attempt and offer the way out at once. */
const UNPLAYABLE = new Set(['mkv', 'avi', 'wmv', 'flv', 'm2ts', 'ts', 'mpg', 'mpeg', 'vob', 'rmvb'])

export function canPlayInBrowser(name: string): boolean {
  return !UNPLAYABLE.has(extension(name))
}

/**
 * Plays a download in the page. While it is still arriving, the bar under the video shows how
 * much exists on disk — with "download in order" that is the playable part; seeking past it waits.
 */
export function PlayerDialog({
  task,
  onClose,
  onCopy,
}: {
  task: TaskRow
  onClose: () => void
  onCopy: (text: string) => void
}) {
  const { t } = useTranslation()
  const ref = useRef<HTMLDivElement>(null)
  const titleId = useId()
  const [failed, setFailed] = useState(() => !canPlayInBrowser(task.name))
  useDialogFocus(ref, { onEscape: onClose })

  const ext = extension(task.name)
  const total = task.totalBytes ?? 0
  const available = total > 0 ? Math.min(1, task.doneBytes / total) : 0
  const complete = task.statusToken === 'completed' || task.statusToken === 'seeding'
  const link = new URL(streamURL(task.id), location.href).toString()

  return (
    <div
      className="scrim open"
      onClick={(e) => {
        if (e.target === e.currentTarget) onClose()
      }}
    >
      <div className="modal player" ref={ref} role="dialog" aria-modal="true" aria-labelledby={titleId}>
        <div className="mhead">
          <h3 id={titleId} className="ell" title={task.name}>
            {task.name}
          </h3>
          <button type="button" className="dx" onClick={onClose} aria-label={t('common.close')}>
            <CloseIcon />
          </button>
        </div>
        <div className="pbody">
          {failed ? (
            <div className="pfallback" role="status">
              <p className="pfall-t">{t('player.cantPlay', { ext: ext ? `.${ext}` : t('player.thisFile') })}</p>
              <p className="fhint">{t('player.cantPlayHint')}</p>
              <div className="pfall-actions">
                {complete && (
                  <a className="btn primary" href={streamURL(task.id, true)} download={task.name}>
                    <DownloadIcon />
                    {t('menu.saveToDevice')}
                  </a>
                )}
                <button type="button" className="btn" onClick={() => onCopy(link)}>
                  <LinkIcon />
                  {t('player.copyLink')}
                </button>
              </div>
            </div>
          ) : (
            <video
              className="pvideo"
              src={streamURL(task.id)}
              controls
              autoPlay
              playsInline
              preload="metadata"
              onError={() => setFailed(true)}
            />
          )}
        </div>
        {!complete && total > 0 && (
          <div className="pbuf">
            <div
              className="pbuf-bar"
              role="progressbar"
              aria-label={t('player.buffered')}
              aria-valuemin={0}
              aria-valuemax={100}
              aria-valuenow={Math.round(pct(available))}
            >
              <i style={{ width: `${pct(available)}%` }} />
            </div>
            <span className="fhint">
              {t('player.bufferedOf', { done: fmtSize(task.doneBytes), total: fmtSize(total) })}
            </span>
          </div>
        )}
      </div>
    </div>
  )
}
