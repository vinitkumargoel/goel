/** Client-side limits for `POST /api/add-torrent`; the server enforces its own. */
export const MAX_TORRENT_BYTES = 10 * 1024 * 1024
export const MAX_TORRENT_FILES = 20
/** The server's cap on one upload's combined size (413 past it). */
export const MAX_TORRENT_TOTAL = 25 * 1024 * 1024

export const TORRENT_ACCEPT = '.torrent,application/x-bittorrent'

export function isTorrentFile(file: Pick<File, 'name' | 'type'>): boolean {
  return file.type === 'application/x-bittorrent' || /\.torrent$/i.test(file.name)
}

export type TorrentRejection = 'notTorrent' | 'tooLarge' | 'tooMany' | 'duplicate' | 'totalTooLarge'

export interface TorrentMerge {
  files: File[]
  rejected: { name: string; reason: TorrentRejection }[]
}

const sameFile = (a: File, b: File) =>
  a.name === b.name && a.size === b.size && a.lastModified === b.lastModified

/** Adds `incoming` to `current`, rejecting non-torrents, oversize files, repeats and anything past the count or total-size caps. */
export function mergeTorrents(current: readonly File[], incoming: readonly File[]): TorrentMerge {
  const files = [...current]
  const rejected: TorrentMerge['rejected'] = []
  for (const file of incoming) {
    const reason: TorrentRejection | null = !isTorrentFile(file)
      ? 'notTorrent'
      : file.size > MAX_TORRENT_BYTES
        ? 'tooLarge'
        : files.some((f) => sameFile(f, file))
          ? 'duplicate'
          : files.length >= MAX_TORRENT_FILES
            ? 'tooMany'
            : files.reduce((sum, f) => sum + f.size, 0) + file.size > MAX_TORRENT_TOTAL
              ? 'totalTooLarge'
              : null
    if (reason) rejected.push({ name: file.name, reason })
    else files.push(file)
  }
  return { files, rejected }
}

/** Whether a drag carries files at all; the item types are all a dragover may read. */
export function dragHasFiles(dt: DataTransfer | null): boolean {
  return dt != null && [...dt.types].includes('Files')
}
