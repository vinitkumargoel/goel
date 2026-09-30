import type { StatusToken, TaskRow } from './types'

/** Work still owed bytes: running now, or waiting its turn. Paused and failed rows are the user's call. */
const PENDING: ReadonlySet<StatusToken> = new Set<StatusToken>(['downloading', 'verifying', 'metadata', 'queued'])

export interface QueueEstimate {
  /** Bytes left across pending downloads whose size is known. */
  remainingBytes: number
  /** Summed download rate right now, bytes per second. */
  rate: number
  /** Seconds until the known bytes land at the current rate; null when nothing is moving or nothing is left. */
  seconds: number | null
  /** Pending downloads whose size is unknown or zero (a magnet still fetching metadata): the estimate leaves them out. */
  unknown: number
}

/**
 * "Can I close the lid yet?" Remaining bytes over the combined rate, not the slowest row's ETA:
 * downloads share one pipe, so a finishing one hands its bandwidth to the rest.
 */
export function queueEstimate(tasks: readonly TaskRow[]): QueueEstimate {
  let remainingBytes = 0
  let rate = 0
  let unknown = 0
  for (const task of tasks) {
    if (!PENDING.has(task.statusToken)) continue
    rate += task.downSpeed > 0 && isFinite(task.downSpeed) ? task.downSpeed : 0
    // Zero is "not known yet" too (a server that hasn't sent Content-Length), as in the Mac app.
    if (task.totalBytes == null || task.totalBytes <= 0) {
      unknown++
      continue
    }
    remainingBytes += Math.max(0, task.totalBytes - task.doneBytes)
  }
  const seconds = remainingBytes > 0 && rate > 0 ? remainingBytes / rate : null
  return { remainingBytes, rate, seconds, unknown }
}

/** "14:32", or with the weekday when it lands on a later day: "Tue 09:10". */
export function fmtFinishAt(seconds: number, nowMs: number = Date.now()): string {
  const at = new Date(nowMs + seconds * 1000)
  const time = at.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
  if (at.toDateString() === new Date(nowMs).toDateString()) return time
  return `${at.toLocaleDateString([], { weekday: 'short' })} ${time}`
}
