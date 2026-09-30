import { useCallback, useEffect, useRef, useState } from 'react'
import { api } from '../lib/api'
import { shareTasks } from '../lib/shareTasks'
import type { TaskRow } from '../lib/types'

const RECONNECT_MS = 2000
const POLL_MS = 2500

interface TasksState {
  tasks: TaskRow[]
  live: boolean
  /** False until the first snapshot lands, so an empty `tasks` can mean "not known yet". */
  loaded: boolean
  /** The last snapshot fetch failed and nothing newer has arrived since. */
  error: boolean
}

export function useTasks(): TasksState & { refresh: () => Promise<void> } {
  const [tasks, setTasks] = useState<TaskRow[]>([])
  const [live, setLive] = useState(false)
  const [loaded, setLoaded] = useState(false)
  const [error, setError] = useState(false)

  // A ref, not a dep: reading `live` in the effect would rebuild the EventSource on every flip.
  const liveRef = useRef(false)
  liveRef.current = live

  /**
   * Bumped by every SSE frame and every fetch start. A fetch applies its result only if the epoch
   * is still the one it started under: an SSE frame or a later fetch is newer than it.
   */
  const epoch = useRef(0)

  const apply = useCallback((next: TaskRow[]) => {
    setTasks((prev) => shareTasks(prev, next))
    setLoaded(true)
    setError(false)
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

  useEffect(() => {
    let source: EventSource | null = null
    let retry: ReturnType<typeof setTimeout> | undefined
    let stopped = false

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
          try {
            source?.close()
          } catch {
          }
          source = null
          retry = setTimeout(connect, RECONNECT_MS)
        }
      } catch {
        setLive(false)
        retry = setTimeout(connect, RECONNECT_MS)
      }
    }

    connect()
    void refresh()

    const poll = setInterval(() => {
      if (!liveRef.current) void refresh()
    }, POLL_MS)

    return () => {
      stopped = true
      clearInterval(poll)
      if (retry) clearTimeout(retry)
      try {
        source?.close()
      } catch {
      }
    }
  }, [apply, refresh])

  return { tasks, live, loaded, error, refresh }
}
