import { useCallback, useEffect, useRef, useState } from 'react'
import { api } from '../lib/api'
import { shareTasks } from '../lib/shareTasks'
import { speedStore, type SpeedStore } from '../lib/speedStore'
import type { TaskRow } from '../lib/types'

const RECONNECT_MS = 2000
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
    let stopped = false

    const close = () => {
      try {
        source?.close()
      } catch {
        // Closing an already-failed source can throw in older engines; there is nothing to undo.
      }
      source = null
    }

    const connect = () => {
      if (stopped) return
      try {
        source = new EventSource('/api/events')
        source.onmessage = (e) => {
          setLive(true)
          try {
            const next = JSON.parse(e.data) as TaskRow[]
            epoch.current++
            apply(next)
          } catch {
            // A malformed frame is dropped: the next snapshot is a full replacement.
          }
        }
        source.onerror = () => {
          setLive(false)
          close()
          retry = setTimeout(connect, RECONNECT_MS)
        }
      } catch {
        setLive(false)
        retry = setTimeout(connect, RECONNECT_MS)
      }
    }

    reconnectRef.current = () => {
      if (stopped) return
      if (retry) clearTimeout(retry)
      retry = undefined
      close()
      connect()
      void refresh()
    }

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
      if (retry) clearTimeout(retry)
      close()
    }
  }, [apply, refresh, speeds])

  const reconnect = useCallback(() => reconnectRef.current(), [])

  return { tasks, live, loaded, error, lastUpdate, refresh, reconnect }
}
