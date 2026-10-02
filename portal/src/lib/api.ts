import i18n from '../i18n'
import type { BandwidthState, BandwidthUpdate } from './bandwidth'
import type {
  TorrentAddOptions,
  TorrentAddResult,
  AddRequest,
  AddResult,
  AddPreviewResult,
  FolderListing,
  HistoryRow,
  NetworkState,
  NetworkUpdate,
  NewFolderRequest,
  NewFolderResult,
  QueuePlacement,
  TrackerEdit,
  TrackerEditResult,
  ScheduleState,
  ServerSettings,
  PortalRule,
  RulesState,
  ServerSettingsUpdate,
  ScheduleUpdate,
  TaskDetail,
  TaskRow,
} from './types'

export type ApiFailure =
  | 'auth'
  | 'refused'
  | 'http'
  | 'network'

export class ApiError extends Error {
  readonly kind: ApiFailure
  readonly status: number

  constructor(kind: ApiFailure, message: string, status = 0) {
    super(message)
    this.name = 'ApiError'
    this.kind = kind
    this.status = status
  }
}

/** A 403 is not only read-only mode: it also covers internal-network targets, out-of-root folders and cross-site POSTs. */
type RefusalSink = (message: string) => void
let onRefused: RefusalSink = () => {}

export function setRefusalHandler(fn: RefusalSink): void {
  onRefused = fn
}

/** Only a short `text/plain` body is ours; anything else is an intermediary's page and must not be shown. */
async function errorText(response: Response): Promise<string> {
  if (!response.headers.get('Content-Type')?.startsWith('text/plain')) return ''
  try {
    const text = (await response.text()).trim()
    return text.length <= 300 ? text : ''
  } catch {
    return ''
  }
}

/**
 * The message a caller should show for a failed action, or `null` when the api layer has already
 * dealt with it: a 403 was toasted by the refusal handler and a 401 is navigating away. Every
 * other failure — an HTTP error or an unreachable server — is the caller's to surface.
 */
export function failureMessage(error: unknown): string | null {
  if (error instanceof ApiError) {
    if (error.kind === 'auth' || error.kind === 'refused') return null
    return error.message || i18n.t('api.actionFailed')
  }
  return i18n.t('api.actionFailed')
}

interface RequestOptions {
  /** Hand back a 400 whose body is JSON instead of throwing: an endpoint's structured refusal. */
  jsonErrors?: boolean
}

async function request(path: string, init?: RequestInit, opts: RequestOptions = {}): Promise<Response> {
  let response: Response
  try {
    response = await fetch(path, init)
  } catch {
    throw new ApiError('network', i18n.t('api.unreachable'))
  }

  if (response.status === 401) {
    // `/`, not `/login`: only the server knows whether this portal challenges or is open.
    location.href = '/'
    throw new ApiError('auth', i18n.t('api.notSignedIn'), 401)
  }

  // The server's own `text/plain` body wins when present; these keys are the fallback wording.
  if (response.status === 403) {
    const message = (await errorText(response)) || i18n.t('api.changeBlocked')
    onRefused(message)
    throw new ApiError('refused', message, 403)
  }

  if (
    opts.jsonErrors &&
    response.status === 400 &&
    response.headers.get('Content-Type')?.startsWith('application/json')
  ) {
    return response
  }

  if (response.status === 413) {
    throw new ApiError('http', i18n.t('api.tooLarge'), 413)
  }

  if (!response.ok) {
    const message =
      (await errorText(response)) || i18n.t('api.requestFailed', { status: response.status })
    throw new ApiError('http', message, response.status)
  }

  return response
}

async function getJSON<T>(path: string): Promise<T> {
  const r = await request(path)
  return (await r.json()) as T
}

async function postJSON<T>(path: string, body: unknown): Promise<T> {
  const r = await request(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
  return (await r.json()) as T
}

/** A JSON body whose answer carries nothing the caller needs. */
async function postOK(path: string, body: unknown): Promise<void> {
  await request(path, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
}

async function post(path: string): Promise<void> {
  await request(path, { method: 'POST' })
}

export const api = {
  tasks: () => getJSON<TaskRow[]>('/api/tasks'),
  task: (id: string) => getJSON<TaskDetail>(`/api/task?id=${encodeURIComponent(id)}`),
  history: () => getJSON<HistoryRow[]>('/api/history'),
  network: () => getJSON<NetworkState>('/api/network'),

  pause: (id: string) => post(`/api/pause?id=${encodeURIComponent(id)}`),
  resume: (id: string) => post(`/api/resume?id=${encodeURIComponent(id)}`),
  retry: (id: string) => post(`/api/retry?id=${encodeURIComponent(id)}`),
  recheck: (id: string) => post(`/api/recheck?id=${encodeURIComponent(id)}`),

  remove: (id: string, withData: boolean) =>
    post(`/api/remove?id=${encodeURIComponent(id)}&data=${withData ? 1 : 0}`),

  filePriority: (taskId: string, fileId: number, priority: string) =>
    post(
      `/api/file-priority?id=${encodeURIComponent(taskId)}&file=${fileId}` +
        `&prio=${encodeURIComponent(priority)}`,
    ),

  folders: (path?: string) =>
    getJSON<FolderListing>('/api/folders' + (path ? `?path=${encodeURIComponent(path)}` : '')),
  createFolder: (body: NewFolderRequest) => postJSON<NewFolderResult>('/api/folder', body),

  add: (body: AddRequest) => postJSON<AddResult>('/api/add', body),
  /** A 404 means a server without the review step; the dialog then adds directly. */
  addPreview: (body: { url: string; folder?: string }) =>
    postJSON<AddPreviewResult>('/api/add-preview', body),
  updateNetwork: (body: NetworkUpdate) => postJSON<NetworkState>('/api/network', body),
  removeHistory: (id: string) => post(`/api/history-remove?id=${encodeURIComponent(id)}`),

  setSequential: (id: string, on: boolean) =>
    post(`/api/sequential?id=${encodeURIComponent(id)}&on=${on ? 1 : 0}`),
  /** 0 or null lifts the cap. */
  setSpeedLimit: (id: string, bytesPerSec: number | null) =>
    post(`/api/speed-limit?id=${encodeURIComponent(id)}&bps=${Math.max(0, Math.round(bytesPerSec ?? 0))}`),
  /** Unix seconds; null starts it whenever the queue gets to it. */
  setStartAt: (id: string, at: number | null) =>
    post(`/api/start-at?id=${encodeURIComponent(id)}&at=${at == null ? 'clear' : Math.round(at)}`),
  move: (ids: readonly string[], to: QueuePlacement, anchor?: string) =>
    postOK('/api/move', { ids, to, anchor }),
  setTags: (id: string, tags: readonly string[]) => postOK('/api/tags', { id, tags }),
  /** Validated server-side; a bad URL refuses the whole request. */
  editTrackers: (body: TrackerEdit) => postJSON<TrackerEditResult>('/api/trackers', body),
  filePriorities: (id: string, files: readonly number[], prio: string) =>
    postOK('/api/file-priorities', { id, files, prio }),
  removeHistoryMany: (ids: readonly string[]) => postOK('/api/history-remove-many', { ids }),
  /** Seconds; omitted clears everything. */
  clearHistory: (olderThan?: number) => postOK('/api/history-clear', { olderThan }),
  /** A 404 means a server without a scheduler (the Linux daemon): callers hide the card. */
  /** A 404 means a server with no editable settings: callers hide the cards. */
  serverSettings: () => getJSON<ServerSettings>('/api/settings'),
  updateServerSettings: (body: ServerSettingsUpdate) => postJSON<ServerSettings>('/api/settings', body),
  /** A 404 means a server with no editable rules: callers hide the card. */
  rules: () => getJSON<RulesState>('/api/rules'),
  /** The whole ordered list replaces the stored one; the echo is what was stored. */
  updateRules: (rules: readonly PortalRule[]) => postJSON<RulesState>('/api/rules', { rules }),
  schedule: () => getJSON<ScheduleState>('/api/schedule'),
  updateSchedule: (body: ScheduleUpdate) => postJSON<ScheduleState>('/api/schedule', body),

  pauseAll: () => post('/api/pause-all'),
  resumeAll: () => post('/api/resume-all'),

  /** A 404 means a daemon older than the bandwidth feature; callers hide it rather than warn. */
  bandwidth: () => getJSON<BandwidthState>('/api/bandwidth'),
  updateBandwidth: (body: BandwidthUpdate) => postJSON<BandwidthState>('/api/bandwidth', body),

  /**
   * Multipart upload: one `file` part per torrent, plus `dir`, `priority` and `paused` as text
   * parts with /api/add's meaning. No Content-Type header — the browser writes it, boundary
   * included. When every file is refused the server answers 400 with the same JSON envelope,
   * which resolves here (added 0, per-file `errors`) rather than throwing.
   */
  addTorrents: async (files: readonly File[], options: TorrentAddOptions = {}): Promise<TorrentAddResult> => {
    const form = new FormData()
    for (const file of files) form.append('file', file, file.name)
    if (options.dir) form.append('dir', options.dir)
    if (options.priority) form.append('priority', options.priority)
    if (options.paused) form.append('paused', '1')
    if (options.network && options.network !== 'auto') form.append('network', options.network)
    if (options.sequential) form.append('sequential', '1')
    if (options.startAt != null) form.append('startAt', String(Math.round(options.startAt)))
    const r = await request('/api/add-torrent', { method: 'POST', body: form }, { jsonErrors: true })
    return (await r.json()) as TorrentAddResult
  },

  logout: async (): Promise<void> => {
    try {
      await post('/logout')
    } catch {
      // Redirect even on failure: a stranded page that looks signed in is worse than a re-challenge at `/`.
    }
    location.href = '/'
  },
}

/**
 * A removal the page is closing on: `keepalive` lets the request outlive the page. Fire and forget —
 * there is nobody left to tell if it fails.
 */
export function removeOnUnload(id: string): void {
  try {
    void fetch(`/api/remove?id=${encodeURIComponent(id)}&data=0`, {
      method: 'POST',
      keepalive: true,
      credentials: 'same-origin',
    }).catch(() => {})
  } catch {
    // A browser without keepalive throws synchronously; nothing more can be done while unloading.
  }
}

/** `download` asks for `Content-Disposition: attachment`, so the browser saves rather than plays. */
export function streamURL(id: string, download = false): string {
  return `/stream?id=${encodeURIComponent(id)}${download ? '&dl=1' : ''}`
}

/** One finished file of a multi-file download, by its `FileRow.id`. */
export function fileURL(id: string, fileId: number): string {
  return `/stream?id=${encodeURIComponent(id)}&file=${fileId}`
}

/** Every finished file of a download as one stored .zip, streamed as it is read. */
export function zipURL(id: string): string {
  return `/stream?id=${encodeURIComponent(id)}&zip=1`
}

/** A History entry's file (or its folder, zipped) — it may have left the queue long ago. */
export function historyFileURL(id: string): string {
  return `/stream?history=${encodeURIComponent(id)}`
}
