import type { StatusToken, TaskKind, TaskRow } from './types'

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

/** The compact form the Mac app's list uses; the long form stays for detail subtitles. */
export const KIND_BADGE: Record<TaskKind, string> = {
  http: 'HTTP',
  torrent: 'BT',
  ftp: 'FTP',
  sftp: 'SFTP',
  hls: 'HLS',
}

export function kindBadge(kind: string): string {
  return KIND_BADGE[kind as TaskKind] ?? kind.toUpperCase()
}

/** The native app's `FileType` cases, in its sidebar order; `magnet` is a transient state, not a kind. */
export type FileType = 'video' | 'audio' | 'image' | 'iso' | 'archive' | 'app' | 'doc' | 'magnet' | 'other'

/**
 * Mirrors the native `FileType.classify` rule list, first match wins, so the Mac and the portal file
 * a download under the same Type. The original four match the extension anywhere ("release.iso.zip"
 * stays a disc image); the newer ones must end the name or a dotted segment.
 */
const TYPE_RULES: ReadonlyArray<readonly [FileType, RegExp]> = [
  ['iso', /\.iso/],
  ['video', /\.(mkv|mp4|avi|mov|webm|m4v|wmv|flv|mpe?g)/],
  ['audio', /\.(mp3|m4a|m4b|aac|flac|wav|ogg|oga|opus|wma|aiff?|alac|ape)(?![a-z0-9])/],
  ['image', /\.(jpe?g|png|gif|heic|heif|webp|tiff?|bmp|svg|avif|psd|raw|cr2|nef|dng)(?![a-z0-9])/],
  ['archive', /\.(zip|gz|tar|7z|rar|dmg|bz2|xz|zst)/],
  ['app', /\.(app|xip|pkg|exe|deb|msi)/],
  ['doc', /\.(pdf|txt|md|rtf|docx?|xlsx?|pptx?|odt|ods|odp|pages|numbers|key|epub|mobi|csv|json|xml|html?)(?![a-z0-9])/],
]

export function fileType(task: Pick<TaskRow, 'name' | 'kind'> & { statusToken: StatusToken | '' }): FileType {
  if (task.statusToken === 'metadata') return 'magnet'
  if (task.kind === 'hls') return 'video'
  const n = task.name.toLowerCase()
  for (const [type, rule] of TYPE_RULES) if (rule.test(n)) return type
  // A torrent with no recognisable extension is almost always a video release (a season pack).
  return task.kind === 'torrent' ? 'video' : 'other'
}

const ACTIVE: ReadonlySet<StatusToken> = new Set<StatusToken>([
  'downloading',
  'metadata',
  'verifying',
  'queued',
])

export function isActive(status: StatusToken): boolean {
  return ACTIVE.has(status)
}

export type RowAction = 'pause' | 'resume' | 'retry'

export function rowAction(status: StatusToken): RowAction | null {
  if (status === 'paused' || status === 'queued') return 'resume'
  if (status === 'failed') return 'retry'
  if (status === 'completed' || status === 'seeding') return null
  return 'pause'
}
