import { describe, expect, it } from 'vitest'
import { makeTask } from '../test/makeTask'
import { withOptimisticStatus } from './optimistic'

describe('withOptimisticStatus', () => {
  const rows = [makeTask('a', { statusToken: 'downloading' }), makeTask('b', { statusToken: 'paused' })]

  it('returns the same array when nothing is in flight', () => {
    expect(withOptimisticStatus(rows, new Map())).toBe(rows)
  })

  it('shows the expected status for a row in flight and leaves the others untouched', () => {
    const out = withOptimisticStatus(rows, new Map([['a', 'pause' as const]]))
    expect(out[0]).toMatchObject({ statusToken: 'paused', busy: true })
    expect(out[1]).toBe(rows[1])
  })

  it('maps resume and retry', () => {
    const out = withOptimisticStatus(rows, new Map([['b', 'resume' as const], ['a', 'retry' as const]]))
    expect(out[1]?.statusToken).toBe('downloading')
    expect(out[0]?.statusToken).toBe('queued')
  })
})
