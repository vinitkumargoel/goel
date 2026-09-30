import { describe, expect, it } from 'vitest'
import { ariaSort, nextSort, sortTasks, UNSORTED } from './sort'
import type { StatusToken, TaskRow } from './types'

function row(id: string, name: string, totalBytes: number | null, statusToken: StatusToken): TaskRow {
  return { id, name, totalBytes, statusToken } as TaskRow
}

const TASKS = [
  row('1', 'file10.iso', 300, 'completed'),
  row('2', 'File2.iso', null, 'downloading'),
  row('3', 'alpha.zip', 100, 'paused'),
]

const ids = (tasks: TaskRow[]) => tasks.map((t) => t.id)

describe('sortTasks', () => {
  it('keeps server order when unsorted, as a copy', () => {
    const out = sortTasks(TASKS, UNSORTED)
    expect(ids(out)).toEqual(['1', '2', '3'])
    expect(out).not.toBe(TASKS)
  })

  it('sorts names naturally and case-insensitively', () => {
    expect(ids(sortTasks(TASKS, { key: 'name', dir: 'asc' }))).toEqual(['3', '2', '1'])
    expect(ids(sortTasks(TASKS, { key: 'name', dir: 'desc' }))).toEqual(['1', '2', '3'])
  })

  it('puts unknown sizes first when ascending', () => {
    expect(ids(sortTasks(TASKS, { key: 'size', dir: 'asc' }))).toEqual(['2', '3', '1'])
  })

  it('orders status by work in flight, then finished', () => {
    expect(ids(sortTasks(TASKS, { key: 'status', dir: 'asc' }))).toEqual(['2', '3', '1'])
  })

  it('does not reorder the input', () => {
    sortTasks(TASKS, { key: 'name', dir: 'asc' })
    expect(ids(TASKS)).toEqual(['1', '2', '3'])
  })
})

describe('ETA and Added', () => {
  const timed = (id: string, etaSeconds: number | null, addedAt: number) =>
    ({ id, etaSeconds, addedAt }) as TaskRow
  const T = [timed('a', null, 300), timed('b', 90, 100), timed('c', 30, 200), timed('d', 0, 50)]

  it('puts the soonest ETA first and unknown or finished ones last', () => {
    expect(ids(sortTasks(T, { key: 'eta', dir: 'asc' }))).toEqual(['c', 'b', 'a', 'd'])
    expect(ids(sortTasks(T, { key: 'eta', dir: 'desc' })).slice(2)).toEqual(['b', 'c'])
  })

  it('sorts by when a download was added', () => {
    expect(ids(sortTasks(T, { key: 'added', dir: 'asc' }))).toEqual(['d', 'b', 'c', 'a'])
    expect(ids(sortTasks(T, { key: 'added', dir: 'desc' }))).toEqual(['a', 'c', 'b', 'd'])
  })
})

describe('nextSort', () => {
  it('starts a new column ascending and flips the active one', () => {
    const byName = nextSort(UNSORTED, 'name')
    expect(byName).toEqual({ key: 'name', dir: 'asc' })
    expect(nextSort(byName, 'name')).toEqual({ key: 'name', dir: 'desc' })
    expect(nextSort({ key: 'name', dir: 'desc' }, 'size')).toEqual({ key: 'size', dir: 'asc' })
  })
})

describe('ariaSort', () => {
  it('reports only the active column', () => {
    const sort = { key: 'size', dir: 'desc' } as const
    expect(ariaSort(sort, 'size')).toBe('descending')
    expect(ariaSort(sort, 'name')).toBe('none')
  })
})
