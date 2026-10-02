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
  /** Client-only: a pause, resume or retry for this row is in flight (see lib/optimistic). */
  busy?: boolean
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
  /** Unix seconds; absent from daemons that predate it. */
  completedAt?: number | null
  etaSeconds: number | null
  error: string | null
  source: string
  multiFile: boolean
  fileCount: number
  streamable: boolean
  /** Bytes/s cap on this one download; null or absent = none. */
  speedLimit?: number | null
  tags?: string[]
  /** 0-based place among queued downloads; null once it has started. */
  queuePosition?: number | null
  priority?: 'low' | 'normal' | 'high'
  /** Unix seconds: held until then. */
  startAt?: number | null
  /** Folder it saves into; absent from daemons that predate it. */
  savePath?: string
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
  /** Absent from older servers. */
  state?: 'working' | 'updating' | 'error' | 'inactive'
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
  /** Task UUIDs for the accepted sources, in request order. */
  ids: string[]
}

/** `POST /api/add-torrent`: the /api/add envelope plus one entry per file the server refused. */
export interface TorrentAddResult {
  added: number
  refused?: number
  ids?: string[]
  errors?: { file: string; error: string }[]
}

export interface TorrentAddOptions {
  /** Blank or missing: the server's default folder. */
  dir?: string
  priority?: 'low' | 'normal' | 'high'
  paused?: boolean
  /** As `AddRequest.network`; left off for `auto`. */
  network?: string
  sequential?: boolean
  startAt?: number
}

export interface AddRequest {
  url: string
  folder?: string
  priority?: 'low' | 'normal' | 'high'
  paused?: boolean
  /** A `NetworkSelection` spec: "auto", "single:eth0", "aggregate", "aggregate:a,b". */
  network?: string
  /** Torrents: fetch pieces in order so the file can be played while it downloads. */
  sequential?: boolean
  /** Unix seconds: queue it now, start it then. */
  startAt?: number
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

/** `GET /api/schedule`: one download window; outside it downloads are held. */
export interface ScheduleState {
  enabled: boolean
  /** Local minutes since midnight. start == end means all day; end < start wraps past midnight. */
  startMinute: number
  endMinute: number
  /** Calendar weekdays: 1 = Sunday … 7 = Saturday. */
  days: number[]
  /** Empty = keep the active profile. */
  profile: string
  profiles: string[]
}

export type ScheduleUpdate = Partial<Omit<ScheduleState, 'profiles'>>

export type QueuePlacement = 'top' | 'bottom' | 'before' | 'after'

/** `/api/add-preview`: one pasted line, by its index among the lines sent. */
export type AddPreviewStatus = 'ok' | 'unsupported' | 'duplicate' | 'refused' | 'credentials' | 'unchecked'

export interface AddPreviewItem {
  index: number
  status: AddPreviewStatus
  /** Null when the probe timed out or could not tell. */
  name: string | null
  kind: TaskKind | null
  totalBytes: number | null
  estimated: boolean
  files: { name: string; size: number }[]
  /** The whole count; `files` stops at 200. */
  fileCount: number
  note: string | null
}

export interface AddPreviewResult {
  items: AddPreviewItem[]
  /** Free space where the add would land; null when the server can't tell. */
  freeBytes: number | null
}

/** `POST /api/trackers`: any mix of adds, removals and one rename. */
export interface TrackerEdit {
  id: string
  add?: string[]
  remove?: string[]
  edit?: { old: string; new: string }
}

export interface TrackerEditResult {
  added: number
  removed: number
  edited: boolean
}

/** `GET /api/settings`: the server settings the portal edits (the desktop's General and BitTorrent panes). */
export interface ServerSettings {
  general: {
    defaultSaveDirectory: string
    defaultFolderRule: 'automatic' | 'byType' | 'bySource' | 'fixed'
    existingFileReaction: 'rename' | 'overwrite'
    /** Of the active traffic profile (`profile`). */
    maxSimultaneousDownloads: number
    profile: string
  }
  bittorrent: {
    encryptionMode: 'prefer' | 'require' | 'disable'
    dht: boolean
    pex: boolean
    lpd: boolean
    utp: boolean
    autoDeleteTorrent: boolean
  }
}

export type ServerSettingsUpdate = {
  general?: Partial<Omit<ServerSettings['general'], 'profile'>>
  bittorrent?: Partial<ServerSettings['bittorrent']>
}
