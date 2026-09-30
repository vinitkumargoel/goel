/**
 * Which placeholder the list shows when it has no rows. Advice has to fit the situation: "tap
 * Add" is wrong before the first snapshot, after a search misses, and for a read-only session.
 */
export type EmptyState =
  /** First snapshot hasn't arrived; the list isn't empty, it's unknown. */
  | 'loading'
  /** No snapshot yet and the last fetch failed. Offers Retry. */
  | 'error'
  /** A search term matches nothing. Offers Clear search. */
  | 'noMatch'
  /** The queue itself is empty and this session may add. Offers Add. */
  | 'emptyQueue'
  /** The queue is empty and this session is read-only. No call to action. */
  | 'emptyReadOnly'
  /** Downloads exist, but none are in the chosen sidebar filter. */
  | 'emptyFilter'

export interface EmptyStateInput {
  loaded: boolean
  /** The last snapshot fetch failed. Only matters before the first snapshot lands. */
  error?: boolean
  /** Every task on the server, before search and filter. */
  total: number
  search: string
  canWrite: boolean
}

export function emptyState({ loaded, error, total, search, canWrite }: EmptyStateInput): EmptyState {
  if (!loaded) return error ? 'error' : 'loading'
  if (search.trim() !== '') return 'noMatch'
  if (total > 0) return 'emptyFilter'
  return canWrite ? 'emptyQueue' : 'emptyReadOnly'
}
