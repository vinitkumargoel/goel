import type { TaskRow } from './types'

/** The limit a user types, in the unit they picked, as bytes/s; null = no limit; undefined = unreadable. */
export type RateUnit = 'KB' | 'MB'

/** Binary, like `fmtSize` and the bandwidth card: "2 MB/s" typed here reads back as 2.0 MB/s. */
const UNIT: Readonly<Record<RateUnit, number>> = { KB: 1024, MB: 1024 * 1024 }

export function parseRate(text: string, unit: RateUnit): number | null | undefined {
  const trimmed = text.trim().replace(',', '.')
  if (trimmed === '' || trimmed === '0') return null
  const value = Number(trimmed)
  if (!Number.isFinite(value) || value < 0) return undefined
  const bytes = Math.round(value * UNIT[unit])
  return bytes === 0 ? null : bytes
}

/** The unit and number a stored limit reads best in, for pre-filling the field. */
export function rateParts(bytesPerSec: number | null | undefined): { value: string; unit: RateUnit } {
  if (!bytesPerSec) return { value: '', unit: 'MB' }
  if (bytesPerSec >= UNIT.MB) {
    return { value: String(Math.round((bytesPerSec / UNIT.MB) * 100) / 100), unit: 'MB' }
  }
  return { value: String(Math.round(bytesPerSec / UNIT.KB)), unit: 'KB' }
}

/** The next local `hour`:00 that is still ahead — "Tonight 01:00" at 23:30 is 90 minutes away. */
export function nextAt(hour: number, now: Date = new Date()): Date {
  const at = new Date(now)
  at.setHours(hour, 0, 0, 0)
  if (at.getTime() <= now.getTime()) at.setDate(at.getDate() + 1)
  return at
}

/** `<input type="datetime-local">` speaks local time with no zone: "2026-09-30T23:15". */
export function toLocalInput(date: Date): string {
  const pad = (n: number) => String(n).padStart(2, '0')
  return (
    `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}` +
    `T${pad(date.getHours())}:${pad(date.getMinutes())}`
  )
}

export function fromLocalInput(value: string): Date | null {
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}/.test(value)) return null
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? null : date
}

export const MAX_TAGS = 32
export const MAX_TAG_LENGTH = 64

/** Comma-separated text to tags: trimmed, blanks and repeats (any case) dropped, bounded like the server. */
export function parseTags(text: string): string[] {
  const out: string[] = []
  const seen = new Set<string>()
  for (const raw of text.split(',')) {
    // eslint-disable-next-line no-control-regex
    const tag = raw.replace(/[\u0000-\u001f\u007f]/g, '').trim().slice(0, MAX_TAG_LENGTH)
    const key = tag.toLowerCase()
    if (!tag || seen.has(key)) continue
    seen.add(key)
    out.push(tag)
    if (out.length === MAX_TAGS) break
  }
  return out
}

/** Every tag in the queue, most used first: the sidebar group and the editor's suggestions. */
export function allTags(tasks: readonly TaskRow[]): { tag: string; count: number }[] {
  const counts = new Map<string, { tag: string; count: number }>()
  for (const t of tasks) {
    for (const tag of t.tags ?? []) {
      const key = tag.toLowerCase()
      const seen = counts.get(key)
      if (seen) seen.count++
      else counts.set(key, { tag, count: 1 })
    }
  }
  return [...counts.values()].sort((a, b) => b.count - a.count || a.tag.localeCompare(b.tag))
}

export function hasTag(task: TaskRow, tag: string): boolean {
  const key = tag.toLowerCase()
  return (task.tags ?? []).some((t) => t.toLowerCase() === key)
}

/** The queue's own run order: rows with a place first by that place, the rest after in list order. */
export function byQueuePosition(tasks: readonly TaskRow[]): TaskRow[] {
  const ranked = tasks.map((task, index) => ({ task, index }))
  ranked.sort((a, b) => {
    const pa = a.task.queuePosition ?? Number.POSITIVE_INFINITY
    const pb = b.task.queuePosition ?? Number.POSITIVE_INFINITY
    return pa === pb ? a.index - b.index : pa - pb
  })
  return ranked.map((r) => r.task)
}
