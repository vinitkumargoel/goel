/** No codegen: these must be edited in lockstep with the Encodables in RemoteRouter.swift. */

export type StatusToken =
  | 'queued'
  | 'metadata'
  | 'downloading'
  | 'verifying'
  | 'paused'
  | 'seeding'
  | 'completed'
  | 'failed'

export type TaskKind = 'http' | 'torrent' | 'hls' | 'ftp' | 'sftp'

export type FilePriority = 'skip' | 'low' | 'normal' | 'high'

export interface TaskRow {
  id: string
  name: string
  status: string
  statusToken: StatusToken
  kind: TaskKind
  progress: number
  downSpeed: number
  upSpeed: number
  totalBytes: number | null
  doneBytes: number
  upBytes: number
  ratio: number
  seeds: number | null
  conns: number
  /** Unix seconds, not milliseconds. */
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
  /** Unix seconds, not milliseconds. */
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
  eligible: boolean
}

export interface NetworkState {
  aggregation: boolean
  streamsPerAdapter: number
  /** Empty means "every eligible adapter", not "none". */
  selected: string[]
  reason: string | null
  locked: boolean
  adapters: NetworkAdapter[]
}

export interface AddResult {
  added: number
  refused: number
}

export interface AddRequest {
  url: string
  folder?: string
  priority?: 'low' | 'normal' | 'high'
  paused?: boolean
  /** A `NetworkSelection` spec: "auto", "single:eth0", "aggregate", "aggregate:a,b". */
  network?: string
}

export interface FolderEntry {
  name: string
  path: string
  readable: boolean
  writable: boolean
}

/** Unrooted: the picker reaches every path the server user can, so it is not a confinement boundary. */
export interface FolderListing {
  path: string
  parent: string | null
  folders: FolderEntry[]
  writable: boolean
  home: string
  defaultFolder: string
  places: FolderEntry[]
}

export interface NewFolderRequest {
  name: string
  parent?: string
}

export interface NewFolderResult {
  path: string
}

export interface NetworkUpdate {
  aggregation?: boolean
  /** Empty array means "all eligible". */
  adapters?: string[]
  streams?: number
}
