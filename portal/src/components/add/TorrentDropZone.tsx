import { useId, useRef, useState, type DragEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { fmtSize } from '../../lib/format'
import { dragHasFiles, MAX_TORRENT_FILES, TORRENT_ACCEPT, type TorrentMerge } from '../../lib/torrentFiles'
import { Art } from '../ui/Art'
import { Icon } from '../ui/Icon'

interface TorrentDropZoneProps {
  files: readonly File[]
  rejected: TorrentMerge['rejected']
  onFiles: (incoming: File[]) => void
  onRemove: (file: File) => void
}

/** The dashed "Drop .torrent files or browse" target, the chosen files as removable chips, and why any were left out. */
export function TorrentDropZone({ files, rejected, onFiles, onRemove }: TorrentDropZoneProps) {
  const { t } = useTranslation()
  const input = useRef<HTMLInputElement>(null)
  const [over, setOver] = useState(false)
  const limitsId = useId()

  const onDragOver = (e: DragEvent<HTMLDivElement>) => {
    if (!dragHasFiles(e.dataTransfer)) return
    e.preventDefault()
    e.dataTransfer.dropEffect = 'copy'
    setOver(true)
  }

  const onDrop = (e: DragEvent<HTMLDivElement>) => {
    if (!dragHasFiles(e.dataTransfer)) return
    // Ours: the dialog-wide and window-level handlers would otherwise see it too.
    e.preventDefault()
    e.stopPropagation()
    setOver(false)
    onFiles([...e.dataTransfer.files])
  }

  return (
    <div className="add-torrents">
      <div
        className={`drop add-drop${over ? ' over' : ''}`}
        onDragOver={onDragOver}
        onDragLeave={() => setOver(false)}
        onDrop={onDrop}
      >
        <Icon name="upload" size="l" />
        <span className="small">
          {t('addDialog.dropTorrents')}{' '}
          <button
            type="button"
            className="add-linkbtn"
            onClick={() => input.current?.click()}
            aria-describedby={limitsId}
          >
            {t('addDialog.browseFiles')}
          </button>
        </span>
        <span className="tiny muted" id={limitsId}>
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
            // Cleared, or choosing the same file again fires no change.
            e.target.value = ''
          }}
        />
      </div>

      {files.length > 0 && (
        <ul className="add-tchips" aria-label={t('addDialog.torrentFiles')}>
          {files.map((f) => (
            <li className="add-tchip" key={`${f.name}-${f.size}-${f.lastModified}`}>
              <Art kind="magnet" size="xs" />
              <span className="ell" title={f.name}>
                {f.name}
              </span>
              <span className="mono faint small">· {fmtSize(f.size)}</span>
              <button
                type="button"
                className="ibtn sm"
                onClick={() => onRemove(f)}
                aria-label={t('addDialog.removeFile', { name: f.name })}
              >
                <Icon name="x" size="s" />
              </button>
            </li>
          ))}
        </ul>
      )}

      <div className="add-rejected" aria-live="polite">
        {rejected.map((r) => (
          <span key={`${r.name}-${r.reason}`} className="err-text">
            {t(`addDialog.rejected.${r.reason}`, { name: r.name, max: MAX_TORRENT_FILES })}
          </span>
        ))}
      </div>
    </div>
  )
}
