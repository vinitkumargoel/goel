import type {
  AddRequest,
  AddResult,
  HistoryRow,
  NetworkState,
  NetworkUpdate,
  TaskDetail,
  TaskRow,
} from './types'

/**
 * Typed client for the remote JSON API (see `docs/remote-api.md`).
 *
 * Auth is by session cookie, so every request is a plain same-origin fetch with
 * no credential handling here. The one exception the server makes — a `?token=`
 * on `GET /` promoted to a cookie — is handled by the shell before this module
 * ever runs.
 */

/** Distinguishes the failure modes callers actually branch on. */
export type ApiFailure =
  /** 401 — the session is gone. A redirect to `/login` is already under way. */
  | 'auth'
  /** 403 — refused. `message` carries the server's own words. */
  | 'refused'
  /** Any other non-2xx. */
  | 'http'
  /** The request never completed — the daemon is down or the network dropped. */
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

/**
 * A 403 is not only read-only mode: the add route also refuses an
 * internal-network target, an out-of-root save folder, and a cross-site POST.
 * The UI surfaces whatever the server said rather than guessing read-only,
 * which is why refusals are routed through a sink instead of being swallowed.
 */
type RefusalSink = (message: string) => void
let onRefused: RefusalSink = () => {}

export function setRefusalHandler(fn: RefusalSink): void {
  onRefused = fn
}

async function request(path: string, init?: RequestInit): Promise<Response> {
  let response: Response
  try {
    response = await fetch(path, init)
  } catch {
    throw new ApiError('network', 'Could not reach the server')
  }

  if (response.status === 401) {
    // The session expired. Going to `/` lets the server decide whether that
    // means the login page or an open portal, instead of assuming.
    location.href = '/'
    throw new ApiError('auth', 'Not signed in', 401)
  }

  if (response.status === 403) {
    let text = ''
    try {
      text = (await response.text()).trim()
    } catch {
      // The body is a nicety; the refusal itself is the signal.
    }
    const message = text || 'Change blocked'
    onRefused(message)
    throw new ApiError('refused', message, 403)
  }

  if (!response.ok) {
    throw new ApiError('http', `Request failed (${response.status})`, response.status)
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

/** POST with no body and no useful response — the mutation routes. */
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

  add: (body: AddRequest) => postJSON<AddResult>('/api/add', body),
  updateNetwork: (body: NetworkUpdate) => postJSON<NetworkState>('/api/network', body),
  removeHistory: (id: string) => post(`/api/history-remove?id=${encodeURIComponent(id)}`),

  logout: async (): Promise<void> => {
    try {
      await post('/logout')
    } catch {
      // A failed sign-out must not strand the user on a page that looks signed
      // in. Fall through to the redirect either way; the cookie is the
      // server's to invalidate and `/` will re-challenge.
    }
    location.href = '/'
  },
}

export function streamURL(id: string): string {
  return `/stream?id=${encodeURIComponent(id)}`
}
