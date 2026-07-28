import { useEffect, useRef, useState } from 'react'
import { api } from '../lib/api'
import type { TaskRow } from '../lib/types'

const RECONNECT_MS = 2000
const POLL_MS = 2500

interface TasksState {
  tasks: TaskRow[]
  live: boolean
}

export function useTasks(): TasksState & { refresh: () => Promise<void> } {
  const [tasks, setTasks] = useState<TaskRow[]>([])
  const [live, setLive] = useState(false)

  // A ref, not a dep: reading `live` in the effect would rebuild the EventSource on every flip.
  const liveRef = useRef(false)
  liveRef.current = live

  const refreshRef = useRef<() => Promise<void>>(async () => {})
  refreshRef.current = async () => {
    try {
      setTasks(await api.tasks())
    } catch {
      // Expected while the daemon restarts; the next tick retries.
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
      }
    }
  }, [])

  return { tasks, live, refresh: () => refreshRef.current() }
}
