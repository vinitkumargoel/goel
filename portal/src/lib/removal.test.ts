import { describe, expect, it } from 'vitest'
import { removalSummary } from './removal'
import type { TaskRow } from './types'

const row = (name: string, totalBytes: number | null, doneBytes = 0) =>
  ({ id: name, name, totalBytes, doneBytes }) as TaskRow

describe('removalSummary', () => {
  it('lists the first five names and counts the rest', () => {
    const rows = ['a', 'b', 'c', 'd', 'e', 'f', 'g'].map((n) => row(n, 10))
    expect(removalSummary(rows, 7)).toEqual({ names: ['a', 'b', 'c', 'd', 'e'], more: 2, bytes: 70 })
  })

  it('falls back to received bytes when the size is unknown', () => {
    expect(removalSummary([row('a', null, 4), row('b', 6)], 2).bytes).toBe(10)
  })

  it('counts ids it has no row for among the rest', () => {
    expect(removalSummary([row('a', 1), undefined], 2)).toEqual({ names: ['a'], more: 1, bytes: 1 })
  })
})
