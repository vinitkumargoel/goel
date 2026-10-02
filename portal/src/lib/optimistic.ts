import type { RowAction } from './taskKind'
import type { StatusToken, TaskRow } from './types'

/** What a row is expected to become once the server has handled the action. */
const EXPECTED: Readonly<Record<RowAction, StatusToken>> = {
  pause: 'paused',
  resume: 'downloading',
  retry: 'queued',
}

/**
 * The rows with each in-flight action applied as the expected status and marked `busy`. Rows with
 * nothing in flight keep their identity, so memoised rows do not re-render; with nothing in
 * flight the same array comes back. Dropping an entry from `inflight` is the rollback.
 */
export function withOptimisticStatus(
  rows: TaskRow[],
  inflight: ReadonlyMap<string, RowAction>,
): TaskRow[] {
  if (inflight.size === 0) return rows
  return rows.map((row) => {
    const action = inflight.get(row.id)
    return action ? { ...row, statusToken: EXPECTED[action], busy: true } : row
  })
}
