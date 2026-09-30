import { failureMessage } from './api'

/** How many per-id requests a bulk action keeps in flight: the server has no batch API. */
export const BULK_CONCURRENCY = 4

/**
 * Runs `fn` over `items` with at most `limit` calls in flight, and settles like
 * `Promise.allSettled`: one result per item, in input order, never rejecting.
 */
export async function runPool<T, R>(
  items: readonly T[],
  limit: number,
  fn: (item: T) => Promise<R>,
): Promise<PromiseSettledResult<R>[]> {
  const results: PromiseSettledResult<R>[] = new Array(items.length)
  let next = 0
  const worker = async () => {
    while (next < items.length) {
      const i = next++
      try {
        results[i] = { status: 'fulfilled', value: await fn(items[i]!) }
      } catch (reason) {
        results[i] = { status: 'rejected', reason }
      }
    }
  }
  const lanes = Math.max(1, Math.min(limit, items.length))
  await Promise.all(Array.from({ length: lanes }, worker))
  return results
}

export type BulkOutcome =
  /** Every call succeeded. */
  | { kind: 'ok'; ok: number; total: number }
  /** Some succeeded, some failed: the user must hear both numbers. */
  | { kind: 'partial'; ok: number; failed: number; total: number }
  /** Nothing succeeded. `reason` is null when the api layer has already said why (403/401). */
  | { kind: 'failed'; failed: number; total: number; reason: string | null }

/** Counts fulfilled against rejected; `reason` is the first failure the caller still has to report. */
export function summariseBulk(results: readonly PromiseSettledResult<unknown>[]): BulkOutcome {
  const total = results.length
  const rejected = results.filter((r): r is PromiseRejectedResult => r.status === 'rejected')
  const failed = rejected.length
  const ok = total - failed
  if (failed === 0) return { kind: 'ok', ok, total }
  if (ok > 0) return { kind: 'partial', ok, failed, total }
  const reason = rejected.map((r) => failureMessage(r.reason)).find((m) => m != null) ?? null
  return { kind: 'failed', failed, total, reason }
}
