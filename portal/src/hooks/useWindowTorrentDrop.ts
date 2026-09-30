import { useEffect } from 'react'
import { dragHasFiles, isTorrentFile } from '../lib/torrentFiles'
import { useStableCallback } from './useStableCallback'

/**
 * A .torrent dropped anywhere on the window hands its files to `onTorrents` (which opens the Add
 * dialog). Every file drop is cancelled either way, so a stray drop never navigates the tab away
 * to the file. `enabled` is false for a read-only session or while the dialog is already open.
 */
export function useWindowTorrentDrop(enabled: boolean, onTorrents: (files: File[]) => void) {
  const handle = useStableCallback(onTorrents)

  useEffect(() => {
    const onDragOver = (e: DragEvent) => {
      if (!dragHasFiles(e.dataTransfer)) return
      e.preventDefault()
      if (e.dataTransfer) e.dataTransfer.dropEffect = enabled ? 'copy' : 'none'
    }
    const onDrop = (e: DragEvent) => {
      if (!dragHasFiles(e.dataTransfer)) return
      e.preventDefault()
      if (!enabled) return
      const torrents = [...(e.dataTransfer?.files ?? [])].filter(isTorrentFile)
      if (torrents.length > 0) handle(torrents)
    }
    window.addEventListener('dragover', onDragOver)
    window.addEventListener('drop', onDrop)
    return () => {
      window.removeEventListener('dragover', onDragOver)
      window.removeEventListener('drop', onDrop)
    }
  }, [enabled, handle])
}
