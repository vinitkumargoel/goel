import type { StatusToken, TaskRow } from './types'

/**
 * The colour a download's state is drawn in, everywhere: status pills, progress arcs and bars,
 * the artwork's fade. Mirrors the app's `StudioDownloadState.tone`.
 *
 * - `acc`     moving: downloading, verifying, fetching metadata
 * - `neutral` waiting: queued
 * - `paused`  held by the user (a grey arc, a faded tile)
 * - `bad`     failed
 * - `up`      seeding
 * - `good`    finished
 */
export type Tone = 'acc' | 'neutral' | 'paused' | 'bad' | 'up' | 'good'

const TONE: Readonly<Record<StatusToken, Tone>> = {
  downloading: 'acc',
  verifying: 'acc',
  metadata: 'acc',
  queued: 'neutral',
  paused: 'paused',
  failed: 'bad',
  seeding: 'up',
  completed: 'good',
}

export function stateTone(task: Pick<TaskRow, 'statusToken'>): Tone {
  return TONE[task.statusToken]
}

/** The `.pill` modifier for a tone: the neutral states share the plain grey pill. */
export function pillClass(tone: Tone): string {
  switch (tone) {
    case 'acc':
      return 'pill acc'
    case 'bad':
      return 'pill bad'
    case 'up':
      return 'pill up'
    case 'good':
      return 'pill good'
    default:
      return 'pill'
  }
}

/** The `.ring` / `.bar` modifier for a tone ('' = the accent default). */
export function meterClass(tone: Tone): string {
  switch (tone) {
    case 'paused':
    case 'neutral':
      return 'paused'
    case 'bad':
      return 'bad'
    case 'up':
      return 'up'
    case 'good':
      return 'good'
    default:
      return ''
  }
}

/** A tile is faded while nothing is happening to it and it isn't finished. */
export function isFaded(task: Pick<TaskRow, 'statusToken'>): boolean {
  return task.statusToken === 'paused'
}

/**
 * The fraction an arc or bar should show: seeding fills toward the seed goal the ratio implies
 * (a 1.20× ratio against the usual 2.00× goal reads 60%), every other state its progress.
 */
export const SEED_GOAL = 2

export function meterFraction(task: Pick<TaskRow, 'statusToken' | 'progress' | 'ratio'>): number {
  if (task.statusToken === 'seeding') return Math.max(0, Math.min(1, task.ratio / SEED_GOAL))
  return Math.max(0, Math.min(1, task.progress))
}
