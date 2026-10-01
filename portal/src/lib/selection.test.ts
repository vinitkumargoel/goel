import { describe, expect, it } from 'vitest'
import { clickAction, EMPTY_SELECTION, selectionReducer, type Selection } from './selection'

const ORDER = ['a', 'b', 'c', 'd', 'e']

function sel(ids: string[], lead: string | null = ids[ids.length - 1] ?? null): Selection {
  return { ids: new Set(ids), lead }
}

const ids = (s: Selection) => [...s.ids].sort()

describe('selectionReducer', () => {
  it('single replaces the selection and moves the lead', () => {
    const next = selectionReducer(sel(['a', 'b']), { type: 'single', id: 'c' })
    expect(ids(next)).toEqual(['c'])
    expect(next.lead).toBe('c')
  })

  it('toggle adds a row and makes it the lead', () => {
    const next = selectionReducer(sel(['a']), { type: 'toggle', id: 'c' })
    expect(ids(next)).toEqual(['a', 'c'])
    expect(next.lead).toBe('c')
  })

  it('toggle drops a row and hands the lead to one still selected', () => {
    const next = selectionReducer(sel(['a', 'c'], 'c'), { type: 'toggle', id: 'c' })
    expect(ids(next)).toEqual(['a'])
    expect(next.lead).toBe('a')
    expect(selectionReducer(next, { type: 'toggle', id: 'a' })).toEqual(EMPTY_SELECTION)
  })

  it('range selects everything between the lead and the target, either direction', () => {
    const down = selectionReducer(sel(['b']), { type: 'range', id: 'd', order: ORDER })
    expect(ids(down)).toEqual(['b', 'c', 'd'])
    expect(down.lead).toBe('b')

    const up = selectionReducer(down, { type: 'range', id: 'a', order: ORDER })
    expect(ids(up)).toEqual(['a', 'b'])
  })

  it('range with no lead selects just the target', () => {
    const next = selectionReducer(EMPTY_SELECTION, { type: 'range', id: 'c', order: ORDER })
    expect(ids(next)).toEqual(['c'])
    expect(next.lead).toBe('c')
  })

  it('range to a row that is not visible is ignored', () => {
    const start = sel(['b'])
    expect(selectionReducer(start, { type: 'range', id: 'zz', order: ORDER })).toBe(start)
  })

  it('all selects every visible row and keeps a visible lead', () => {
    const next = selectionReducer(sel(['c']), { type: 'all', order: ORDER })
    expect(ids(next)).toEqual(ORDER)
    expect(next.lead).toBe('c')
    expect(selectionReducer(sel(['zz']), { type: 'all', order: ORDER }).lead).toBe('a')
    expect(selectionReducer(sel(['c']), { type: 'all', order: [] })).toEqual(EMPTY_SELECTION)
  })

  it('prune drops vanished rows and returns the same object when nothing changed', () => {
    const start = sel(['a', 'b'], 'b')
    const next = selectionReducer(start, { type: 'prune', existing: ['a', 'c'] })
    expect(ids(next)).toEqual(['a'])
    expect(next.lead).toBeNull()
    expect(selectionReducer(start, { type: 'prune', existing: ORDER })).toBe(start)
  })

  it('never mutates the previous state', () => {
    const start = sel(['a'])
    selectionReducer(start, { type: 'toggle', id: 'b' })
    selectionReducer(start, { type: 'toggle', id: 'a' })
    expect(ids(start)).toEqual(['a'])
  })
})

describe('clickAction', () => {
  it('maps modifiers the way a desktop list does', () => {
    expect(clickAction('b', { shift: false, toggle: false }, ORDER)).toEqual({ type: 'single', id: 'b' })
    expect(clickAction('b', { shift: false, toggle: true }, ORDER)).toEqual({ type: 'toggle', id: 'b' })
    expect(clickAction('b', { shift: true, toggle: true }, ORDER)).toEqual({
      type: 'range',
      id: 'b',
      order: ORDER,
    })
  })

  it('set selects exactly the given rows with the first as lead', () => {
    const s = selectionReducer(selectionReducer(EMPTY_SELECTION, { type: 'single', id: 'x' }), {
      type: 'set',
      ids: ['b', 'c'],
    })
    expect([...s.ids]).toEqual(['b', 'c'])
    expect(s.lead).toBe('b')
    expect(selectionReducer(s, { type: 'set', ids: [] })).toBe(EMPTY_SELECTION)
  })
})
