import type {
  AddRequest,
  AddResult,
  FolderListing,
  HistoryRow,
  NetworkState,
  NetworkUpdate,
  NewFolderRequest,
  NewFolderResult,
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

async function request(path: string, init?: RequestInit): Promise<Response> {
  let response: Response
  try {
    response = await fetch(path, init)
  } catch {
    throw new ApiError('network', 'Could not reach the server')
  }

  if (response.status === 401) {
    // `/`, not `/login`: only the server knows whether this portal challenges or is open.
    location.href = '/'
    throw new ApiError('auth', 'Not signed in', 401)
  }

  if (response.status === 403) {
    const message = (await errorText(response)) || 'Change blocked'
    onRefused(message)
    throw new ApiError('refused', message, 403)
  }

  if (!response.ok) {
    const message = (await errorText(response)) || `Request failed (${response.status})`
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
  updateNetwork: (body: NetworkUpdate) => postJSON<NetworkState>('/api/network', body),
  removeHistory: (id: string) => post(`/api/history-remove?id=${encodeURIComponent(id)}`),

  logout: async (): Promise<void> => {
    try {
      await post('/logout')
    } catch {
      // Redirect even on failure: a stranded page that looks signed in is worse than a re-challenge at `/`.
    }
    location.href = '/'
  },
}

export function streamURL(id: string): string {
  return `/stream?id=${encodeURIComponent(id)}`
}
