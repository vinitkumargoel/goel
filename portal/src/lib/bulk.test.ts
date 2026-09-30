import { describe, expect, it } from 'vitest'
import { ApiError, failureMessage } from './api'
import { runPool, summariseBulk } from './bulk'

const ok = (): PromiseSettledResult<void> => ({ status: 'fulfilled', value: undefined })
const bad = (reason: unknown): PromiseSettledResult<void> => ({ status: 'rejected', reason })

describe('runPool', () => {
  it('never has more than `limit` calls in flight', async () => {
    let inFlight = 0
    let peak = 0
    const results = await runPool([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 4, async (n) => {
      inFlight++
      peak = Math.max(peak, inFlight)
      await new Promise((r) => setTimeout(r, 1))
      inFlight--
      return n * 2
    })
    expect(peak).toBe(4)
    expect(results.map((r) => (r.status === 'fulfilled' ? r.value : null))).toEqual([
      2, 4, 6, 8, 10, 12, 14, 16, 18, 20,
    ])
  })

  it('settles every item in input order and never rejects', async () => {
    const results = await runPool(['a', 'b', 'c'], 2, async (id) => {
      if (id === 'b') throw new Error('nope')
      return id
    })
    expect(results.map((r) => r.status)).toEqual(['fulfilled', 'rejected', 'fulfilled'])
  })

  it('handles an empty list', async () => {
    expect(await runPool([], 4, async () => 1)).toEqual([])
  })
})

describe('summariseBulk', () => {
  it('reports full success', () => {
    expect(summariseBulk([ok(), ok()])).toEqual({ kind: 'ok', ok: 2, total: 2 })
  })

  it('counts a partial failure rather than calling it a success', () => {
    expect(summariseBulk([ok(), bad(new ApiError('http', 'boom', 500)), ok(), ok(), bad(new Error('x'))])).toEqual({
      kind: 'partial',
      ok: 3,
      failed: 2,
      total: 5,
    })
  })

  it('gives the first reportable reason when everything failed', () => {
    const outcome = summariseBulk([bad(new ApiError('http', 'Disk full', 500)), bad(new ApiError('network', 'x'))])
    expect(outcome).toEqual({ kind: 'failed', failed: 2, total: 2, reason: 'Disk full' })
  })

  it('has no reason when the api layer already surfaced every failure', () => {
    const refused = new ApiError('refused', 'Read-only', 403)
    expect(summariseBulk([bad(refused), bad(refused)])).toMatchObject({ kind: 'failed', reason: null })
  })
})

describe('failureMessage', () => {
  it('stays quiet for refusals and sign-outs, which the api layer handles', () => {
    expect(failureMessage(new ApiError('refused', 'no', 403))).toBeNull()
    expect(failureMessage(new ApiError('auth', 'no', 401))).toBeNull()
  })

  it('surfaces http and network failures, with a fallback for anything else', () => {
    expect(failureMessage(new ApiError('http', 'Request failed (500)', 500))).toBe('Request failed (500)')
    expect(failureMessage(new ApiError('network', 'Could not reach the server'))).toBe(
      'Could not reach the server',
    )
    expect(failureMessage(new TypeError('bad json'))).toBe('That didn’t work — try again')
  })
})
