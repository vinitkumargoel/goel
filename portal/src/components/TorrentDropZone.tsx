import { useId, useRef, useState, type DragEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { fmtSize } from '../lib/format'
import {
  dragHasFiles,
  MAX_TORRENT_FILES,
  TORRENT_ACCEPT,
  type TorrentMerge,
} from '../lib/torrentFiles'
import { CloseIcon, UploadIcon } from './Icons'

interface TorrentDropZoneProps {
  files: readonly File[]
  rejected: TorrentMerge['rejected']
  onFiles: (incoming: File[]) => void
  onRemove: (file: File) => void
}

/** The dashed "Drop .torrent files or browse" target, plus the chosen files as removable chips. */
export function TorrentDropZone({ files, rejected, onFiles, onRemove }: TorrentDropZoneProps) {
  const { t } = useTranslation()
  const input = useRef<HTMLInputElement>(null)
  const [over, setOver] = useState(false)
  const id = useId()

  const onDragOver = (e: DragEvent<HTMLDivElement>) => {
    if (!dragHasFiles(e.dataTransfer)) return
    e.preventDefault()
    e.dataTransfer.dropEffect = 'copy'
    setOver(true)
  }

  const onDrop = (e: DragEvent<HTMLDivElement>) => {
    if (!dragHasFiles(e.dataTransfer)) return
    // Ours: the window-level handler would otherwise see it too.
    e.preventDefault()
    e.stopPropagation()
    setOver(false)
    onFiles([...e.dataTransfer.files])
  }

  return (
    <div className="tdrop-wrap">
      <div
        className={`tdrop${over ? ' over' : ''}`}
        onDragOver={onDragOver}
        onDragLeave={() => setOver(false)}
        onDrop={onDrop}
      >
        <UploadIcon aria-hidden="true" />
        <span>
          {t('addDialog.dropTorrents')}{' '}
          <button type="button" className="linkbtn" onClick={() => input.current?.click()} aria-describedby={`${id}-lim`}>
            {t('addDialog.browseFiles')}
          </button>
        </span>
        <span className="tdrop-lim" id={`${id}-lim`}>
          {t('addDialog.torrentLimits', { count: MAX_TORRENT_FILES })}
        </span>
        <input
          ref={input}
          type="file"
          accept={TORRENT_ACCEPT}
          multiple
          hidden
          aria-label={t('addDialog.torrentFiles')}
          onChange={(e) => {
            onFiles([...(e.target.files ?? [])])
            // Clear it, or choosing the same file again fires no change.
            e.target.value = ''
          }}
        />
      </div>

      {files.length > 0 && (
        <ul className="tchips" aria-label={t('addDialog.torrentFiles')}>
          {files.map((f) => (
            <li className="tchip" key={`${f.name}-${f.size}-${f.lastModified}`}>
              <span className="tchip-n" title={f.name}>
                {f.name}
              </span>
              <span className="tchip-s">· {fmtSize(f.size)}</span>
              <button
                type="button"
                className="tchip-x"
                onClick={() => onRemove(f)}
                aria-label={t('addDialog.removeFile', { name: f.name })}
              >
                <CloseIcon aria-hidden="true" />
              </button>
            </li>
          ))}
        </ul>
      )}

      <div className="fcount fwarn" aria-live="polite">
        {rejected.map((r) => (
          <div key={`${r.name}-${r.reason}`}>
            {t(`addDialog.rejected.${r.reason}`, { name: r.name, max: MAX_TORRENT_FILES })}
          </div>
        ))}
      </div>
    </div>
  )
}
