import { useCallback, useSyncExternalStore } from 'react'
import { EMPTY_HISTORY, recordFrame, type SpeedHistory, type SpeedSample } from './speedHistory'
import type { TaskRow } from './types'

const NO_SAMPLES: readonly SpeedSample[] = []

/**
 * The speed history, held outside React state. The sampler writes once a second; only the two
 * charts subscribe, so a tick re-renders a sparkline and (when open) the Progress chart — not the
 * whole app, as it did when the history lived in `App`'s state.
 */
export class SpeedStore {
  private history: SpeedHistory = EMPTY_HISTORY
  private readonly listeners = new Set<() => void>()

  readonly subscribe = (listener: () => void): (() => void) => {
    this.listeners.add(listener)
    return () => {
      this.listeners.delete(listener)
    }
  }

  readonly snapshot = (): SpeedHistory => this.history

  /** Folds a frame in; listeners hear of it only when the history actually changed. */
  record(rows: readonly TaskRow[]): void {
    const next = recordFrame(this.history, rows)
    if (next === this.history) return
    this.history = next
    for (const listener of this.listeners) listener()
  }

  reset(): void {
    if (this.history === EMPTY_HISTORY) return
    this.history = EMPTY_HISTORY
    for (const listener of this.listeners) listener()
  }
}

/** The app's one store: `useTasks` samples into it, the charts read from it. */
export const speedStore = new SpeedStore()

/**
 * One series: a task's, or `'total'` for the summed rates. The same array comes back until that
 * series gains a sample, so an unrelated task's tick does not re-render this subscriber.
 */
export function useSpeedSeries(id: string, store: SpeedStore = speedStore): readonly SpeedSample[] {
  const select = useCallback(() => {
    const history = store.snapshot()
    return id === 'total' ? history.total : (history.perTask.get(id) ?? NO_SAMPLES)
  }, [id, store])
  return useSyncExternalStore(store.subscribe, select, select)
}
