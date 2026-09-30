import { describe, expect, it } from 'vitest'
import { emptyState } from './emptyState'

const base = { loaded: true, total: 0, search: '', canWrite: true }

describe('emptyState', () => {
  it('is loading until the first snapshot, whatever else is true', () => {
    expect(emptyState({ ...base, loaded: false })).toBe('loading')
    expect(emptyState({ ...base, loaded: false, search: 'x', total: 5 })).toBe('loading')
  })

  it('offers Clear search when a search is active', () => {
    expect(emptyState({ ...base, search: 'ubuntuu', total: 3 })).toBe('noMatch')
    // A search on an empty queue still explains the search, not the queue.
    expect(emptyState({ ...base, search: 'x' })).toBe('noMatch')
  })

  it('ignores a whitespace-only search', () => {
    expect(emptyState({ ...base, search: '   ' })).toBe('emptyQueue')
  })

  it('tells an empty filter from an empty queue', () => {
    expect(emptyState({ ...base, total: 4 })).toBe('emptyFilter')
  })

  it('invites Add only when the session can write', () => {
    expect(emptyState(base)).toBe('emptyQueue')
    expect(emptyState({ ...base, canWrite: false })).toBe('emptyReadOnly')
  })
})
