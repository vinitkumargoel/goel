import type { ScheduleState } from './types'

/** Calendar weekdays in display order, Monday first: 2 … 7, then 1 (Sunday). */
export const WEEK: readonly number[] = [2, 3, 4, 5, 6, 7, 1]

export const HOURS: readonly number[] = Array.from({ length: 24 }, (_, h) => h)

type Window = Pick<ScheduleState, 'startMinute' | 'endMinute' | 'days'>

/**
 * The scheduler's own rule (AutomationCore.isWindowOpen), for one minute of one weekday:
 * start == end is always open; end < start wraps, and the part after midnight belongs to the
 * previous day's window.
 */
export function isOpenAt(w: Window, weekday: number, minute: number): boolean {
  const { startMinute: s, endMinute: e, days } = w
  if (s === e) return true
  if (s < e) return days.includes(weekday) && minute >= s && minute < e
  if (minute >= s) return days.includes(weekday)
  if (minute < e) return days.includes(weekday === 1 ? 7 : weekday - 1)
  return false
}

/** A grid cell is painted when any minute of its hour is inside the window. */
export function cellOpen(w: Window, weekday: number, hour: number): boolean {
  const from = hour * 60
  if (isOpenAt(w, weekday, from) || isOpenAt(w, weekday, from + 59)) return true
  const inHour = (m: number) => m > from && m < from + 60
  return (inHour(w.startMinute) && isOpenAt(w, weekday, w.startMinute)) || inHour(w.endMinute)
}

/** Dragging across hours a…b (either direction) paints one contiguous window. */
export function paintRange(a: number, b: number): { startMinute: number; endMinute: number } {
  const lo = Math.min(a, b)
  const hi = Math.max(a, b)
  return { startMinute: lo * 60, endMinute: ((hi + 1) * 60) % 1440 }
}

/** Clicking a day in or out; the last day cannot go (the server refuses an empty week). */
export function toggleDay(days: readonly number[], day: number): number[] {
  if (days.includes(day)) return days.length === 1 ? [...days] : days.filter((d) => d !== day)
  return [...days, day].sort((x, y) => x - y)
}

export function fmtMinute(minute: number): string {
  const m = ((minute % 1440) + 1440) % 1440
  return `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`
}

/** A stable colour per profile name, so "Night" is the same colour on every visit. */
const PALETTE = ['#5b8def', '#34c759', '#ff9f0a', '#bf5af2', '#ff6482', '#64d2ff', '#ffd60a']

export function profileColor(name: string, profiles: readonly string[]): string {
  if (!name) return 'var(--accent)'
  const i = profiles.indexOf(name)
  if (i >= 0) return PALETTE[i % PALETTE.length]!
  let hash = 0
  for (const ch of name) hash = (hash * 31 + ch.charCodeAt(0)) >>> 0
  return PALETTE[hash % PALETTE.length]!
}

export function sameSchedule(a: ScheduleState, b: ScheduleState): boolean {
  return (
    a.enabled === b.enabled &&
    a.startMinute === b.startMinute &&
    a.endMinute === b.endMinute &&
    a.profile === b.profile &&
    a.days.join() === b.days.join()
  )
}
