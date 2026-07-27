/**
 * Wire types for the remote JSON API.
 *
 * These mirror the `Encodable` structs in
 * `Sources/GoelCore/Remote/RemoteRouter.swift` field-for-field — `TaskRow`,
 * `TaskDetail`, `FileRow`, `TrackerRow`, `ConnRow`, `HistoryRow`, `ConfigRow`
 * and `RemoteNetworkState`. If you change a field there, change it here; there
 * is no code generation across the boundary and nothing else will catch it.
 *
 * Swift `Int64?`/`Double?` become `number | null` rather than `number |
 * undefined`: `JSONEncoder` omits nothing here, it emits an explicit null.
 */

/** `RemoteRouter.statusToken(_:)` — the stable tokens, not the display names. */
export type StatusToken =
  | 'queued'
  | 'metadata'
  | 'downloading'
  | 'verifying'
  | 'paused'
  | 'seeding'
  | 'completed'
  | 'failed'

/** `DownloadKind.rawValue`. */
export type TaskKind = 'http' | 'torrent' | 'hls' | 'ftp' | 'sftp'

/** `RemoteRouter.priorityToken(_:)`. */
export type FilePriority = 'skip' | 'low' | 'normal' | 'high'

export interface TaskRow {
  id: string
  name: string
  /** Localized display name ("Downloading"). Render this; branch on `statusToken`. */
  status: string
  statusToken: StatusToken
  kind: TaskKind
  /** 0…1, not a percentage. */
  progress: number
  downSpeed: number
  upSpeed: number
  /** Null until the server learns the length (magnet metadata, chunked HTTP). */
  totalBytes: number | null
  doneBytes: number
  upBytes: number
  ratio: number
  seeds: number | null
  conns: number
  /** Unix seconds. */
  addedAt: number
  etaSeconds: number | null
  error: string | null
  source: string
  multiFile: boolean
  fileCount: number
  streamable: boolean
}

export interface FileRow {
  id: number
  /** `TransferFile.path` — a path within the torrent, not a basename. */
  name: string
  size: number
  done: number
  progress: number
  priority: FilePriority
}

export interface TrackerRow {
  url: string
  host: string
  tier: number
  status: string
  seeds: number | null
  leeches: number | null
  message: string
}

export interface ConnRow {
  id: string
  label: string
  detail: string
  down: number
  up: number
  progress: number
  adapterId: string | null
  adapterLabel: string | null
}

export interface TaskDetail {
  row: TaskRow
  savePath: string
  sequential: boolean
  infoHash: string | null
  files: FileRow[]
  trackers: TrackerRow[]
  connections: ConnRow[]
  /** Per-bucket availability, 0…1. Empty for non-torrents. */
  pieces: number[]
  server: string | null
  mimeType: string | null
}

export interface HistoryRow {
  id: string
  name: string
  kind: TaskKind
  totalBytes: number | null
  savePath: string
  /** Unix seconds. */
  completedAt: number
  source: string
}

export interface ConfigRow {
  username: string
  readOnly: boolean
  requireAuth: boolean
  theme: string
}

export interface NetworkAdapter {
  name: string
  label: string
  type: string
  ipv4: string | null
  expensive: boolean
  /** False when the interface exists but cannot be bound right now. Grey it out. */
  eligible: boolean
}

export interface NetworkState {
  aggregation: boolean
  streamsPerAdapter: number
  /** Empty means "every eligible adapter", not "none". */
  selected: string[]
  /** Why aggregation is not currently running; null when it is. */
  reason: string | null
  /** `/etc/goel/config` pins `GOEL_AGGREGATION`, so a change here is temporary. */
  locked: boolean
  adapters: NetworkAdapter[]
}

/** Response from `POST /api/add`. */
export interface AddResult {
  added: number
  refused: number
}

/** Request body for `POST /api/add`. */
export interface AddRequest {
  url: string
  folder?: string
  priority?: 'low' | 'normal' | 'high'
  paused?: boolean
  /** A `NetworkSelection` spec: "auto", "single:eth0", "aggregate", "aggregate:a,b". */
  network?: string
}

/** Request body for `POST /api/network`. */
export interface NetworkUpdate {
  aggregation?: boolean
  /** Empty array means "all eligible". */
  adapters?: string[]
  streams?: number
}
