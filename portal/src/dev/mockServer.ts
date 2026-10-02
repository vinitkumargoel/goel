/**
 * A fake daemon for `npm run dev` with `?fixtures`: answers every /api route from dev/fixtures.ts,
 * streams a frame a second with the downloads moving, and applies actions to its own state.
 *
 *   ?fixtures            the mockup's queue
 *   ?fixtures=empty      nothing queued yet (the first-run welcome)
 *   ?fixtures=loading    the first snapshot never arrives
 *   ?fixtures=error      the snapshot fetch fails
 *   ?fixtures=offline    live at first, then the stream drops (the reconnect banner)
 *   ?fixtures=readonly   a read-only session: every POST is refused
 *
 * Installed by dev/install.ts only under `import.meta.env.DEV`; never in the production bundle.
 */
import type { TaskRow } from '../lib/types'
import {
  sampleBandwidth,
  sampleDetail,
  sampleFolders,
  sampleHistory,
  sampleNetwork,
  samplePreview,
  sampleSchedule,
  sampleTasks,
} from './fixtures'

export type FixtureMode = 'full' | 'empty' | 'loading' | 'error' | 'offline' | 'readonly'

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
const ok = () => new Response('', { status: 200 })

export function installMockServer(mode: FixtureMode): void {
  let tasks: TaskRow[] = mode === 'empty' || mode === 'loading' || mode === 'error' ? [] : sampleTasks()
  let history = sampleHistory()
  let bandwidth = sampleBandwidth()
  let schedule = sampleSchedule()
  let network = sampleNetwork()
  let offline = false
  if (mode === 'offline') setTimeout(() => (offline = true), 2500)

  const update = (id: string | null, patch: (t: TaskRow) => TaskRow) => {
    tasks = tasks.map((t) => (t.id === id ? patch(t) : t))
  }

  const tick = () => {
    tasks = tasks.map((t) => {
      if (t.statusToken !== 'downloading' || !t.totalBytes) return t
      const wobble = 0.8 + Math.random() * 0.4
      const speed = Math.round((t.id === 'cosmos' ? 24 : t.id === 'ubuntu' ? 12 : 7.7) * 1024 * 1024 * wobble)
      const done = Math.min(t.totalBytes, t.doneBytes + speed / 40)
      return {
        ...t,
        doneBytes: done,
        progress: done / t.totalBytes,
        downSpeed: speed,
        etaSeconds: Math.round((t.totalBytes - done) / speed),
      }
    })
  }

  const realFetch = window.fetch.bind(window)
  window.fetch = async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(typeof input === 'string' ? input : input instanceof URL ? input.href : input.url, location.href)
    if (!url.pathname.startsWith('/api/') && url.pathname !== '/logout') return realFetch(input, init)
    await new Promise((r) => setTimeout(r, 120))
    const method = (init?.method ?? 'GET').toUpperCase()
    const id = url.searchParams.get('id')
    const body = typeof init?.body === 'string' ? (JSON.parse(init.body) as Record<string, unknown>) : {}

    if (method === 'GET') {
      switch (url.pathname) {
        case '/api/tasks':
          if (mode === 'loading') return new Promise<Response>(() => {})
          if (mode === 'error' || offline) throw new TypeError('Failed to fetch')
          return json(tasks)
        case '/api/task': {
          const task = tasks.find((t) => t.id === id)
          return task ? json(sampleDetail(task)) : json({}, 404)
        }
        case '/api/history':
          return json(history)
        case '/api/network':
          return json(network)
        case '/api/folders':
          return json(sampleFolders(url.searchParams.get('path') ?? undefined))
        case '/api/bandwidth':
          return json(bandwidth)
        case '/api/schedule':
          return json(schedule)
      }
      return json({}, 404)
    }

    if (mode === 'readonly' && url.pathname !== '/logout') {
      return new Response('This session is read-only.', { status: 403, headers: { 'Content-Type': 'text/plain' } })
    }

    switch (url.pathname) {
      case '/api/pause':
        update(id, (t) => ({ ...t, status: 'Paused', statusToken: 'paused', downSpeed: 0, etaSeconds: null }))
        return ok()
      case '/api/resume':
        update(id, (t) => ({ ...t, status: 'Downloading', statusToken: 'downloading', queuePosition: null }))
        return ok()
      case '/api/retry':
        update(id, (t) => ({ ...t, status: 'Downloading', statusToken: 'downloading', error: null }))
        return ok()
      case '/api/remove':
        tasks = tasks.filter((t) => t.id !== id)
        return ok()
      case '/api/pause-all':
        tasks = tasks.map((t) => (t.statusToken === 'downloading' || t.statusToken === 'queued' ? { ...t, status: 'Paused', statusToken: 'paused', downSpeed: 0 } : t))
        return ok()
      case '/api/resume-all':
        tasks = tasks.map((t) => (t.statusToken === 'paused' ? { ...t, status: 'Downloading', statusToken: 'downloading' } : t))
        return ok()
      case '/api/add-preview':
        return json(samplePreview(String(body['url'] ?? '').split(/\n/).map((l) => l.trim()).filter(Boolean)))
      case '/api/add': {
        const lines = String(body['url'] ?? '').split(/\n/).map((l) => l.trim()).filter(Boolean)
        const ids = lines.map((line, i) => {
          const tid = `new${Date.now()}${i}`
          tasks = [
            ...tasks,
            {
              ...sampleTasks()[4]!,
              id: tid,
              name: decodeURIComponent(line.split('/').pop() || line),
              source: line,
              queuePosition: tasks.length,
              addedAt: Math.floor(Date.now() / 1000),
            },
          ]
          return tid
        })
        return json({ added: ids.length, refused: 0, ids })
      }
      case '/api/history-remove':
        history = history.filter((h) => h.id !== id)
        return ok()
      case '/api/history-remove-many': {
        const ids = new Set((body['ids'] as string[]) ?? [])
        history = history.filter((h) => !ids.has(h.id))
        return ok()
      }
      case '/api/history-clear': {
        const older = body['olderThan'] as number | undefined
        const cutoff = Date.now() / 1000 - (older ?? 0)
        history = older == null ? [] : history.filter((h) => h.completedAt > cutoff)
        return ok()
      }
      case '/api/bandwidth':
        bandwidth = { ...bandwidth, ...(body as object) }
        return json(bandwidth)
      case '/api/schedule':
        schedule = { ...schedule, ...(body as object) }
        return json(schedule)
      case '/api/network':
        network = { ...network, ...(body['aggregation'] != null ? { aggregation: Boolean(body['aggregation']) } : {}) }
        return json(network)
      case '/api/folder':
        return json({ path: `${String(body['parent'] ?? '/Users/dev/Downloads')}/${String(body['name'])}` })
      case '/api/trackers':
        return json({ added: 1, removed: 0, edited: false })
      case '/api/add-torrent':
        return json({ added: 1, ids: [] })
      case '/logout':
        return ok()
      default:
        return ok()
    }
  }

  class MockEventSource {
    onmessage: ((e: MessageEvent) => void) | null = null
    onerror: ((e: Event) => void) | null = null
    readyState = 0
    private timer: ReturnType<typeof setInterval> | undefined
    constructor(public url: string) {
      if (mode === 'loading' || mode === 'error') {
        setTimeout(() => this.onerror?.(new Event('error')), 50)
        return
      }
      const send = () => {
        if (offline) {
          clearInterval(this.timer)
          this.onerror?.(new Event('error'))
          return
        }
        tick()
        this.onmessage?.(new MessageEvent('message', { data: JSON.stringify(tasks) }))
      }
      setTimeout(send, 30)
      this.timer = setInterval(send, 1000)
    }
    addEventListener() {
      // The mock sends a frame every second, so it never needs the server ping.
    }
    close() {
      clearInterval(this.timer)
    }
  }
  ;(window as unknown as { EventSource: unknown }).EventSource = MockEventSource
}
