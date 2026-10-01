import { useCallback, useEffect, useRef, useState } from 'react'
import { api, failureMessage } from '../lib/api'
import { createLatest } from '../lib/latest'
import type { FilePriority, TaskDetail, TaskRow } from '../lib/types'

export const DETAIL_POLL_MS = 4000

/**
 * The detail panel's data for `detailId`: fetched when the id changes, refetched every
 * `DETAIL_POLL_MS` while `polling` (a completed task is static and is not re-polled), and
 * patched with the live row from each snapshot in between.
 *
 * Responses are sequence-guarded: only the latest request for the id still selected may land, so
 * a slow response for a previous row can never paint over the current one. A failed refetch keeps
 * the detail already shown; only a failed first load of a new id clears it.
 */
export function useDetail(
  detailId: string | null,
  tasks: readonly TaskRow[],
  polling: boolean,
  /** A failed priority change; not called for a 403, which the api layer already reported. */
  onWarn: (message: string) => void,
) {
  const [detail, setDetail] = useState<TaskDetail | null>(null)
  const latest = useRef(createLatest())
  const idRef = useRef(detailId)
  idRef.current = detailId

  const load = useCallback(async (id: string) => {
    const stamp = latest.current.begin()
    try {
      const next = await api.task(id)
      if (latest.current.isCurrent(stamp) && idRef.current === id) setDetail(next)
    } catch {
      if (!latest.current.isCurrent(stamp) || idRef.current !== id) return
      setDetail((d) => (d && d.row.id === id ? d : null))
    }
  }, [])

  useEffect(() => {
    if (detailId == null) {
      latest.current.invalidate()
      setDetail(null)
      return
    }
    void load(detailId)
  }, [detailId, load])

  // Without this the panel's progress bar only moves on the 4s refetch while the list behind it updates live.
  useEffect(() => {
    if (detailId == null) return
    const row = tasks.find((t) => t.id === detailId)
    if (!row) return
    setDetail((d) => (d && d.row.id === detailId && d.row !== row ? { ...d, row } : d))
  }, [tasks, detailId])

  const pollRef = useRef<() => void>(() => {})
  pollRef.current = () => {
    if (detailId == null || !polling) return
    const row = tasks.find((t) => t.id === detailId)
    if (!row || row.statusToken !== 'completed') void load(detailId)
  }
  useEffect(() => {
    const timer = setInterval(() => pollRef.current(), DETAIL_POLL_MS)
    return () => clearInterval(timer)
  }, [])

  /** Refetch now, e.g. after changing a file's priority. */
  const reload = useCallback(() => (idRef.current == null ? Promise.resolve() : load(idRef.current)), [load])

  const setFilePriority = useCallback(
    async (fileId: number, priority: string) => {
      const id = idRef.current
      if (id == null) return
      try {
        await api.filePriority(id, fileId, priority)
        await load(id)
      } catch (e) {
        const message = failureMessage(e)
        if (message) onWarn(message)
      }
    },
    [load, onWarn],
  )

  /** Many files, one priority, one request — a folder checkbox or "Only video". */
  const setFilePriorities = useCallback(
    async (fileIds: readonly number[], priority: FilePriority) => {
      const id = idRef.current
      if (id == null || fileIds.length === 0) return
      try {
        await api.filePriorities(id, fileIds, priority)
      } catch (e) {
        const message = failureMessage(e)
        if (message) onWarn(message)
      }
      await load(id)
    },
    [load, onWarn],
  )

  const cyclePriority = useCallback(
    (fileId: number, current: FilePriority) => {
      const order: FilePriority[] = ['low', 'normal', 'high']
      const next = order[(order.indexOf(current) + 1) % order.length]!
      void setFilePriority(fileId, next)
    },
    [setFilePriority],
  )

  return { detail, reload, setFilePriority, setFilePriorities, cyclePriority }
}
