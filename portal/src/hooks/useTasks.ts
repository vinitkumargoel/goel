import { useCallback, useEffect, useRef, useState } from 'react'
import { api } from '../lib/api'
import { shareTasks } from '../lib/shareTasks'
import { speedStore, type SpeedStore } from '../lib/speedStore'
import type { TaskRow } from '../lib/types'

const RECONNECT_BASE_MS = 1000
const RECONNECT_CAP_MS = 30_000
/** The server pings every 15 s; two missed pings and the stream is treated as frozen. */
export const WATCHDOG_MS = 35_000

/** Exponential backoff with full-ish jitter: 1 s, 2 s, 4 s … capped at 30 s. `rand` is in [0, 1). */
export function reconnectDelay(attempt: number, rand: number = Math.random()): number {
  const ceiling = Math.min(RECONNECT_CAP_MS, RECONNECT_BASE_MS * 2 ** Math.max(0, attempt))
  return Math.round(ceiling / 2 + (ceiling / 2) * rand)
}
const POLL_MS = 2500
/**
 * The chart's clock. The stream only sends a frame when something changed, so sampling per frame
 * would stall on an idle queue and stretch the x-axis; one sample a second of the latest rows keeps
 * "60 samples" equal to "the last minute".
 */
export const SAMPLE_MS = 1000
/** Off the stream, rows older than this stop feeding the chart (matches the reconnect banner). */
const STALE_SAMPLE_MS = 5000

interface TasksState {
  tasks: TaskRow[]
  live: boolean
  /** False until the first snapshot lands, so an empty `tasks` can mean "not known yet". */
  loaded: boolean
  /** The last snapshot fetch failed and nothing newer has arrived since. */
  error: boolean
  /** When the latest snapshot arrived (ms since epoch), or null before the first. */
  lastUpdate: number | null
}

interface TasksApi {
  refresh: () => Promise<void>
  /** Drops any pending backoff and reopens the event stream now, fetching a snapshot alongside. */
  reconnect: () => void
}

/**
 * The queue, live. Rates are sampled once a second into `speeds` (see `lib/speedStore`), not into
 * state here: the charts subscribe to it themselves, so a tick never re-renders the caller.
 */
export function useTasks(speeds: SpeedStore = speedStore): TasksState & TasksApi {
  const [tasks, setTasks] = useState<TaskRow[]>([])
  const [live, setLive] = useState(false)
  const [loaded, setLoaded] = useState(false)
  const [error, setError] = useState(false)
  const [lastUpdate, setLastUpdate] = useState<number | null>(null)

  // A ref, not a dep: reading `live` in the effect would rebuild the EventSource on every flip.
  const liveRef = useRef(false)
  liveRef.current = live

  /**
   * Bumped by every SSE frame and every fetch start. A fetch applies its result only if the epoch
   * is still the one it started under: an SSE frame or a later fetch is newer than it.
   */
  const epoch = useRef(0)

  /** The newest rows and when they came, for the sampler. */
  const latest = useRef<{ rows: TaskRow[]; at: number } | null>(null)

  const apply = useCallback((next: TaskRow[]) => {
    latest.current = { rows: next, at: Date.now() }
    setTasks((prev) => shareTasks(prev, next))
    setLoaded(true)
    setError(false)
    setLastUpdate(Date.now())
  }, [])

  // Stable identity: it is a dep of every action callback, and through them of each memoised row.
  const refresh = useCallback(async () => {
    const started = ++epoch.current
    try {
      const next = await api.tasks()
      if (epoch.current === started) apply(next)
    } catch {
      // Expected while the daemon restarts; the next tick retries. Shown only if nothing newer came.
      if (epoch.current === started) setError(true)
    }
  }, [apply])

  const reconnectRef = useRef<() => void>(() => {})

  useEffect(() => {
    let source: EventSource | null = null
    let retry: ReturnType<typeof setTimeout> | undefined
    let watchdog: ReturnType<typeof setTimeout> | undefined
    let attempt = 0
    let stopped = false

    const close = () => {
      if (watchdog) clearTimeout(watchdog)
      watchdog = undefined
      try {
        source?.close()
      } catch {
        // Closing an already-failed source can throw in older engines; there is nothing to undo.
      }
      source = null
    }

    const scheduleRetry = () => {
      if (stopped) return
      setLive(false)
      close()
      if (retry) clearTimeout(retry)
      retry = setTimeout(connect, reconnectDelay(attempt++))
    }

    /** Any frame or ping proves the stream is alive; silence past the watchdog means it froze. */
    const heard = () => {
      attempt = 0
      if (watchdog) clearTimeout(watchdog)
      watchdog = setTimeout(scheduleRetry, WATCHDOG_MS)
    }

    function connect() {
      if (stopped) return
      retry = undefined
      try {
        const es = new EventSource('/api/events')
        source = es
        heard()
        es.addEventListener('ping', () => {
          setLive(true)
          heard()
        })
        es.onmessage = (e) => {
          setLive(true)
          heard()
          try {
            const next = JSON.parse(e.data) as TaskRow[]
            epoch.current++
            apply(next)
          } catch {
            // A malformed frame is dropped: the next snapshot is a full replacement.
          }
        }
        es.onerror = scheduleRetry
      } catch {
        scheduleRetry()
      }
    }

    reconnectRef.current = () => {
      if (stopped) return
      if (retry) clearTimeout(retry)
      retry = undefined
      attempt = 0
      close()
      connect()
      void refresh()
    }

    /** A tab coming back or the network returning: the socket may be dead without having said so. */
    const wake = () => {
      if (document.visibilityState === 'hidden') return
      reconnectRef.current()
    }
    document.addEventListener('visibilitychange', wake)
    window.addEventListener('online', wake)

    connect()
    void refresh()

    const poll = setInterval(() => {
      if (!liveRef.current) void refresh()
    }, POLL_MS)

    const sampler = setInterval(() => {
      // Nobody sees a chart in a background tab; the browser throttles the timer there anyway.
      if (document.visibilityState === 'hidden') return
      const snap = latest.current
      if (!snap) return
      // A live stream only sends changes, so its rows stay current however old; off the stream,
      // rows older than a missed poll or two are stale, and the chart must not draw them as live.
      if (!liveRef.current && Date.now() - snap.at > STALE_SAMPLE_MS) return
      speeds.record(snap.rows)
    }, SAMPLE_MS)

    return () => {
      stopped = true
      clearInterval(poll)
      clearInterval(sampler)
      document.removeEventListener('visibilitychange', wake)
      window.removeEventListener('online', wake)
      if (retry) clearTimeout(retry)
      close()
    }
  }, [apply, refresh, speeds])

  const reconnect = useCallback(() => reconnectRef.current(), [])

  return { tasks, live, loaded, error, lastUpdate, refresh, reconnect }
}
