/**
 * A request-sequence guard. `begin()` stamps a request; only the most recently begun one is
 * current, so a slow response can never overwrite a newer one. `invalidate()` retires every
 * request in flight without starting a new one.
 */
export interface Latest {
  begin(): number
  isCurrent(stamp: number): boolean
  invalidate(): void
}

export function createLatest(): Latest {
  let seq = 0
  return {
    begin: () => ++seq,
    isCurrent: (stamp) => stamp === seq,
    invalidate: () => {
      seq++
    },
  }
}
