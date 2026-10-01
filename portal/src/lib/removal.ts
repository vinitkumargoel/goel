import type { TaskRow } from './types'

/** How many names a bulk-remove confirmation lists before "and N more". */
export const REMOVAL_NAMES = 5

export interface RemovalSummary {
  names: string[]
  /** Rows beyond the listed names (including ones no longer known). */
  more: number
  /** On-disk size, as far as it is known: the total, else what has arrived. */
  bytes: number
}

/** What a bulk removal covers, for its confirmation. `count` is the ids asked for. */
export function removalSummary(rows: readonly (TaskRow | undefined)[], count: number): RemovalSummary {
  const known = rows.filter((row): row is TaskRow => row != null)
  const names = known.slice(0, REMOVAL_NAMES).map((row) => row.name)
  const bytes = known.reduce((sum, row) => sum + (row.totalBytes ?? row.doneBytes ?? 0), 0)
  return { names, more: Math.max(0, count - names.length), bytes }
}
