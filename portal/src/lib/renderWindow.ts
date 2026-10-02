/**
 * Incremental rendering for a long library. Every list operation (keyboard order, ranges, select
 * all) works on the full `order`; only the DOM is capped, to the first `limit` items in that order.
 */
export const WINDOW_THRESHOLD = 300
export const WINDOW_PAGE = 300

/** The ids to draw, or null when the list is short enough to draw whole. */
export function windowIds(order: readonly string[], limit: number): ReadonlySet<string> | null {
  if (order.length <= WINDOW_THRESHOLD || limit >= order.length) return null
  return new Set(order.slice(0, limit))
}

/** The limit that makes `id` (and a page after it) drawn; unchanged when it already is. */
export function limitToInclude(order: readonly string[], limit: number, id: string): number {
  const at = order.indexOf(id)
  return at < 0 || at < limit ? limit : at + WINDOW_PAGE
}
