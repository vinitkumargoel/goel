import { describe, expect, it } from 'vitest'
import { groupTasks } from './grouping'
import type { TaskRow } from './types'

const NOW = new Date(2026, 8, 30, 12).getTime()
const task = (id: string, over: Partial<TaskRow>): TaskRow =>
  ({ id, name: id, statusToken: 'queued', source: 'https://a.example/x', addedAt: NOW / 1000, ...over }) as TaskRow

describe('groupTasks', () => {
  const rows = [
    task('a', { statusToken: 'completed', source: 'magnet:?xt=urn:btih:1' }),
    task('b', { statusToken: 'downloading', source: 'https://b.example/y', addedAt: NOW / 1000 - 86_400 }),
    task('c', { statusToken: 'completed', addedAt: NOW / 1000 - 30 * 86_400 }),
  ]

  it('is empty for no grouping', () => {
    expect(groupTasks(rows, 'none', NOW)).toEqual([])
  })

  it('orders status groups work-first and keeps row order within', () => {
    const groups = groupTasks(rows, 'status', NOW)
    expect(groups.map((g) => [g.key, g.tasks.map((t) => t.id)])).toEqual([
      ['downloading', ['b']],
      ['completed', ['a', 'c']],
    ])
  })

  it('buckets by date added', () => {
    expect(groupTasks(rows, 'added', NOW).map((g) => g.key)).toEqual(['today', 'yesterday', 'older'])
  })

  it('sorts hosts alphabetically with magnets last', () => {
    expect(groupTasks(rows, 'host', NOW).map((g) => g.key)).toEqual(['a.example', 'b.example', ''])
  })
})
