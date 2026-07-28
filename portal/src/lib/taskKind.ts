import type { StatusToken, TaskKind, TaskRow } from './types'

/** Protocol labels for the row badges and the detail subtitle. */
export const KIND_LABEL: Record<TaskKind, string> = {
  http: 'HTTP',
  torrent: 'BitTorrent',
  ftp: 'FTP',
  sftp: 'SFTP',
  hls: 'HLS',
}

export function kindLabel(kind: string): string {
  return KIND_LABEL[kind as TaskKind] ?? kind
}

/** Drives the coloured tile next to a row. Purely cosmetic. */
export type FileType = 'iso' | 'video' | 'archive' | 'app' | 'magnet' | 'doc'

/** Guess a file type from the name; a torrent still fetching metadata shows the magnet tile, and a
 *  `.mkv` in a torrent is still video — the tile describes the payload, the badge the protocol. */
export function fileType(task: Pick<TaskRow, 'name' | 'kind'> & { statusToken: StatusToken | '' }): FileType {
  const n = task.name.toLowerCase()
  if (task.statusToken === 'metadata') return 'magnet'
  if (/\.iso($|\?)/.test(n)) return 'iso'
  if (task.kind === 'torrent' && /\.(mkv|mp4|avi|mov)/.test(n)) return 'video'
  if (/\.(mkv|mp4|avi|mov|m3u8|webm)/.test(n) || task.kind === 'hls') return 'video'
  if (/\.(zip|gz|tar|7z|rar|dmg|zst|xz)/.test(n)) return 'archive'
  if (/\.(app|xip|pkg|exe|dmg)/.test(n)) return 'app'
  return 'doc'
}

/** The statuses the "Active" sidebar filter counts. */
const ACTIVE: ReadonlySet<StatusToken> = new Set<StatusToken>([
  'downloading',
  'metadata',
  'verifying',
  'queued',
])

export function isActive(status: StatusToken): boolean {
  return ACTIVE.has(status)
}

/** The single action a row's inline button offers, or null when there is nothing useful to do
 *  (a completed or seeding task). */
export type RowAction = 'pause' | 'resume' | 'retry'

export function rowAction(status: StatusToken): RowAction | null {
  if (status === 'paused' || status === 'queued') return 'resume'
  if (status === 'failed') return 'retry'
  if (status === 'completed' || status === 'seeding') return null
  return 'pause'
}
