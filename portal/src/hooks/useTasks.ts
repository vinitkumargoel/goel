import { useEffect, useRef, useState } from 'react'
import { api } from '../lib/api'
import type { TaskRow } from '../lib/types'

/** How long to wait before rebuilding a dropped `EventSource`. */
const RECONNECT_MS = 2000
/** Poll cadence used *only* while the stream is down. */
const POLL_MS = 2500

interface TasksState {
  tasks: TaskRow[]
  /** True while the SSE stream is delivering. Drives the fallback poll. */
  live: boolean
}

/**
 * The live task list.
 *
 * `GET /api/events` pushes a full snapshot on every change, so there is no
 * patching to get wrong — each message replaces the array. Polling exists only
 * as a fallback for when the stream is down (a proxy that buffers SSE, a
 * sleeping laptop), and stops as soon as it comes back; running both at once
 * would double the load on the daemon for no extra freshness.
 */
export function useTasks(): TasksState & { refresh: () => Promise<void> } {
  const [tasks, setTasks] = useState<TaskRow[]>([])
  const [live, setLive] = useState(false)

  // Read by the poll timer, which must see the current value without being torn
  // down and rebuilt every time the connection state flips.
  const liveRef = useRef(false)
  liveRef.current = live

  const refreshRef = useRef<() => Promise<void>>(async () => {})
  refreshRef.current = async () => {
    try {
      setTasks(await api.tasks())
    } catch {
      // Expected while the daemon restarts. The next tick tries again; a toast
      // on every failed poll would be a stream of noise during a restart.
    }
  }

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
            setTasks(JSON.parse(e.data) as TaskRow[])
          } catch {
            // A malformed frame is not worth tearing the stream down for — the
            // next snapshot is a full replacement anyway.
          }
        }
        source.onerror = () => {
          setLive(false)
          try {
            source?.close()
          } catch {
            // Already closed.
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
    void refreshRef.current()

    const poll = setInterval(() => {
      if (!liveRef.current) void refreshRef.current()
    }, POLL_MS)

    return () => {
      stopped = true
      clearInterval(poll)
      if (retry) clearTimeout(retry)
      try {
        source?.close()
      } catch {
        // Already closed.
      }
    }
  }, [])

  return { tasks, live, refresh: () => refreshRef.current() }
}
